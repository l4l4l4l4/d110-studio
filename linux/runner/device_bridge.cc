#include "device_bridge.h"

#include <bluetooth/bluetooth.h>
#include <bluetooth/rfcomm.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {
constexpr size_t kImageLimit = 16 * 1024 * 1024;
constexpr size_t kReplyLimit = 64 * 1024;
constexpr size_t kStateLimit = 64 * 1024 * 1024;
using Clock = std::chrono::steady_clock;
using Call = std::shared_ptr<FlMethodCall>;

struct Request {
  Call call;
  std::string method;
  std::string text;
  std::string path;
  std::vector<uint8_t> bytes;
  int expected = 0;
  int timeout = 3000;
};

struct Reply {
  enum Kind { kNull, kBytes, kText, kDevices, kAdapter } kind = kNull;
  bool available = false;
  bool enabled = false;
  std::vector<uint8_t> bytes;
  std::string text;
  std::vector<std::pair<std::string, std::string>> devices;
  std::string code;
  std::string message;
  int os_error = 0;

  bool Error(const char* error_code, const std::string& description, int number) {
    code = error_code;
    message = description;
    os_error = number;
    return false;
  }
  bool SystemError(const std::string& operation, int number = errno) {
    return Error("bluetooth_error", operation + ": " + std::strerror(number) +
                 " (errno " + std::to_string(number) + ")", number);
  }
};

void Respond(FlMethodCall* call, const Reply& reply) {
  g_autoptr(GError) error = nullptr;
  gboolean sent;
  if (!reply.code.empty()) {
    g_autoptr(FlValue) detail = fl_value_new_int(reply.os_error);
    sent = fl_method_call_respond_error(call, reply.code.c_str(),
                                        reply.message.c_str(), detail, &error);
  } else {
    g_autoptr(FlValue) value = nullptr;
    switch (reply.kind) {
      case Reply::kNull:
        break;
      case Reply::kAdapter:
        value = fl_value_new_map();
        fl_value_set_string_take(value, "available", fl_value_new_bool(reply.available));
        fl_value_set_string_take(value, "enabled", fl_value_new_bool(reply.enabled));
        fl_value_set_string_take(value, "permitted", fl_value_new_bool(true));
        break;
      case Reply::kBytes:
        value = fl_value_new_uint8_list(reply.bytes.data(), reply.bytes.size());
        break;
      case Reply::kText:
        value = fl_value_new_string_sized(reply.text.data(), reply.text.size());
        break;
      case Reply::kDevices:
        value = fl_value_new_list();
        for (const auto& device : reply.devices) {
          FlValue* entry = fl_value_new_map();
          fl_value_set_string_take(entry, "name", fl_value_new_string(device.first.c_str()));
          fl_value_set_string_take(entry, "address", fl_value_new_string(device.second.c_str()));
          fl_value_append_take(value, entry);
        }
        break;
    }
    sent = fl_method_call_respond_success(call, value, &error);
  }
  if (!sent && error) g_warning("Device channel reply failed: %s", error->message);
}

FlValue* Argument(FlValue* args, const char* name, FlValueType type) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* value = fl_value_lookup_string(args, name);
  return value && fl_value_get_type(value) == type ? value : nullptr;
}

bool ReadFile(const std::string& path, bool image, bool missing_ok, Reply& reply,
              bool state = false) {
  int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) {
    int number = errno;
    if (missing_ok && number == ENOENT) {
      if (state) return true;
      reply.kind = Reply::kText;
      reply.text = "[]";
      return true;
    }
    return reply.Error("file_error", "Opening file: " + std::string(std::strerror(number)), number);
  }
  struct stat metadata;
  if (fstat(fd, &metadata) != 0) {
    int number = errno;
    close(fd);
    return reply.Error("file_error", "Reading file metadata: " + std::string(std::strerror(number)), number);
  }
  if (!S_ISREG(metadata.st_mode) ||
      ((image || state) && metadata.st_size > static_cast<off_t>(state ? kStateLimit : kImageLimit))) {
    close(fd);
    return reply.Error("file_error", "Select a regular image file no larger than 16 MiB", EFBIG);
  }
  std::vector<uint8_t> contents;
  if (metadata.st_size > 0) contents.reserve(static_cast<size_t>(metadata.st_size));
  uint8_t buffer[8192];
  for (;;) {
    ssize_t count = read(fd, buffer, sizeof(buffer));
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) {
      int number = errno;
      close(fd);
      return reply.Error("file_error", "Reading file: " + std::string(std::strerror(number)), number);
    }
    if (count == 0) break;
    if (state && contents.size() + static_cast<size_t>(count) > kStateLimit) {
      close(fd);
      return reply.Error("file_error", "State exceeds the 64 MiB limit", EFBIG);
    }
    if (image && contents.size() + static_cast<size_t>(count) > kImageLimit) {
      close(fd);
      return reply.Error("file_error", "Image exceeds the 16 MiB limit", EFBIG);
    }
    contents.insert(contents.end(), buffer, buffer + count);
  }
  close(fd);
  if (image) {
    reply.kind = Reply::kBytes;
    reply.bytes = std::move(contents);
  } else {
    if (!contents.empty() && !g_utf8_validate(reinterpret_cast<const char*>(contents.data()), contents.size(), nullptr))
      return reply.Error("file_error", "Saved templates are not valid UTF-8", EILSEQ);
    reply.kind = Reply::kText;
    reply.text.assign(contents.begin(), contents.end());
  }
  return true;
}
}  // namespace

struct DeviceBridge::Impl {
  FlMethodChannel* channel;
  GtkWindow* window;
  GtkWidget* chooser = nullptr;
  Call picker_call;
  GMainContext* context;
  GCancellable* cancellable;
  std::shared_ptr<std::atomic<bool>> alive = std::make_shared<std::atomic<bool>>(true);
  std::atomic<bool> stopping{false};
  std::mutex queue_mutex;
  std::condition_variable ready;
  std::deque<Request> queue;
  std::mutex socket_mutex;
  int socket_fd = -1;
  std::thread worker;
  std::string template_directory;

  Impl(FlBinaryMessenger* messenger, GtkWindow* parent)
      : window(parent), context(g_main_context_ref_thread_default()),
        cancellable(g_cancellable_new()) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    channel = fl_method_channel_new(messenger, "d110_studio/device", FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel, [](FlMethodChannel*, FlMethodCall* call, gpointer data) {
      static_cast<Impl*>(data)->Handle(call);
    }, this, nullptr);
    template_directory = std::string(g_get_user_data_dir()) + "/d110-studio";
    worker = std::thread([this] { Run(); });
  }

  ~Impl() {
    alive->store(false);
    fl_method_channel_set_method_call_handler(channel, nullptr, nullptr, nullptr);
    if (chooser) {
      g_signal_handlers_disconnect_by_data(chooser, this);
      gtk_widget_destroy(chooser);
      chooser = nullptr;
    }
    picker_call.reset();
    stopping.store(true);
    g_cancellable_cancel(cancellable);
    {
      std::lock_guard<std::mutex> lock(socket_mutex);
      if (socket_fd >= 0) shutdown(socket_fd, SHUT_RDWR);
    }
    ready.notify_one();
    worker.join();
    g_object_unref(channel);
    g_object_unref(cancellable);
    g_main_context_unref(context);
  }

  void Complete(Call call, Reply reply) {
    struct Completion {
      Call call;
      Reply reply;
      std::shared_ptr<std::atomic<bool>> alive;
      FlMethodChannel* channel;
    };
    auto* completion = new Completion{std::move(call), std::move(reply), alive, channel};
    // An idle source (rather than g_main_context_invoke) never executes replies
    // inline on the worker, even when the UI context is temporarily unowned.
    GSource* source = g_idle_source_new();
    g_source_set_callback(source, [](gpointer data) -> gboolean {
      auto* value = static_cast<Completion*>(data);
      if (value->alive->load()) {
        if (value->call) Respond(value->call.get(), value->reply);
        else fl_method_channel_invoke_method(value->channel, "disconnected", nullptr, nullptr, nullptr, nullptr);
      }
      return G_SOURCE_REMOVE;
    }, completion, [](gpointer data) { delete static_cast<Completion*>(data); });
    g_source_attach(source, context);
    g_source_unref(source);
  }

  void Enqueue(Request request) {
    {
      std::lock_guard<std::mutex> lock(queue_mutex);
      queue.push_back(std::move(request));
    }
    ready.notify_one();
  }

  void Handle(FlMethodCall* call) {
    Request request;
    request.call = Call(FL_METHOD_CALL(g_object_ref(call)), [](FlMethodCall* value) { g_object_unref(value); });
    request.method = fl_method_call_get_name(call);
    FlValue* args = fl_method_call_get_args(call);
    Reply error;
    if (request.method == "connect" || request.method == "saveLastPrinterAddress") {
      FlValue* address = Argument(args, "address", FL_VALUE_TYPE_STRING);
      if (!address) {
        error.Error("invalid_argument", "connect requires an address string", EINVAL);
        Respond(call, error);
        return;
      }
      request.text = fl_value_get_string(address);
    } else if (request.method == "write" || request.method == "exchange") {
      FlValue* bytes = Argument(args, "bytes", FL_VALUE_TYPE_UINT8_LIST);
      if (!bytes) {
        error.Error("invalid_argument", "bytes must be a Uint8List", EINVAL);
        Respond(call, error);
        return;
      }
      size_t size = fl_value_get_length(bytes);
      if (size) request.bytes.assign(fl_value_get_uint8_list(bytes), fl_value_get_uint8_list(bytes) + size);
      if (request.method == "exchange") {
        FlValue* expected = Argument(args, "expectedLength", FL_VALUE_TYPE_INT);
        FlValue* timeout = Argument(args, "timeoutMs", FL_VALUE_TYPE_INT);
        if (!expected || !timeout || fl_value_get_int(expected) < 0 ||
            fl_value_get_int(expected) > static_cast<int64_t>(kReplyLimit) ||
            fl_value_get_int(timeout) < 1 || fl_value_get_int(timeout) > 30000) {
          error.Error("invalid_argument", "exchange requires expectedLength 0..65536 and timeoutMs 1..30000", EINVAL);
          Respond(call, error);
          return;
        }
        request.expected = static_cast<int>(fl_value_get_int(expected));
        request.timeout = static_cast<int>(fl_value_get_int(timeout));
      }
    } else if (request.method == "readState" || request.method == "writeState") {
      FlValue* slot = Argument(args, "slot", FL_VALUE_TYPE_STRING);
      const std::string name = slot ? fl_value_get_string(slot) : "";
      if (name == "lastPrinted") request.path = "last-printed.json";
      else if (name == "workspace") request.path = "workspace.json";
      else if (name == "mediaProfile") request.path = "media-profile.json";
      else {
        error.Error("invalid_argument", "Unknown state slot", EINVAL);
        Respond(call, error);
        return;
      }
      if (request.method == "writeState") {
        FlValue* json = Argument(args, "json", FL_VALUE_TYPE_STRING);
        if (!json || std::strlen(fl_value_get_string(json)) > kStateLimit) {
          error.Error("invalid_argument", "State JSON must not exceed 64 MiB", EINVAL);
          Respond(call, error);
          return;
        }
        request.text = fl_value_get_string(json);
      }
    } else if (request.method == "saveTemplates") {
      FlValue* json = Argument(args, "json", FL_VALUE_TYPE_STRING);
      if (!json) {
        error.Error("invalid_argument", "saveTemplates requires a JSON string", EINVAL);
        Respond(call, error);
        return;
      }
      request.text = fl_value_get_string(json);
    } else if (request.method == "pickImage") {
      PickImage(std::move(request.call));
      return;
    } else if (request.method != "devices" && request.method != "disconnect" &&
               request.method != "loadTemplates" && request.method != "lastPrinterAddress" &&
               request.method != "adapterState" && request.method != "requestEnableBluetooth") {
      fl_method_call_respond_not_implemented(call, nullptr);
      return;
    }
    Enqueue(std::move(request));
  }

  void PickImage(Call call) {
    if (chooser) {
      Reply error;
      error.Error("busy", "An image chooser is already open", EBUSY);
      Respond(call.get(), error);
      return;
    }
    picker_call = std::move(call);
    chooser = gtk_file_chooser_dialog_new("Choose label image", window,
        GTK_FILE_CHOOSER_ACTION_OPEN, "Cancel", GTK_RESPONSE_CANCEL,
        "Open", GTK_RESPONSE_ACCEPT, nullptr);
    gtk_window_set_modal(GTK_WINDOW(chooser), TRUE);
    GtkFileFilter* filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Images");
    gtk_file_filter_add_pixbuf_formats(filter);
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(chooser), filter);
    g_signal_connect(chooser, "response", G_CALLBACK(+[](GtkDialog* dialog, gint response, gpointer data) {
      auto* self = static_cast<Impl*>(data);
      Call selected_call = std::move(self->picker_call);
      gchar* path = response == GTK_RESPONSE_ACCEPT ? gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog)) : nullptr;
      self->chooser = nullptr;
      gtk_widget_destroy(GTK_WIDGET(dialog));
      if (!path) {
        Respond(selected_call.get(), Reply{});
        return;
      }
      Request request;
      request.call = std::move(selected_call);
      request.method = "pickImage";
      request.path = path;
      g_free(path);
      self->Enqueue(std::move(request));
    }), this);
    gtk_widget_show(chooser);
  }

  void CloseSocket() {
    std::lock_guard<std::mutex> lock(socket_mutex);
    if (socket_fd >= 0) {
      shutdown(socket_fd, SHUT_RDWR);
      close(socket_fd);
      socket_fd = -1;
      Complete(Call{}, Reply{});
    }
  }

  bool WaitSocket(short events, Clock::time_point deadline, Reply& reply, bool quiet = false) {
    for (;;) {
      if (stopping.load()) return reply.Error("cancelled", "Application is closing", ECANCELED);
      auto now = Clock::now();
      auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
      if (now >= deadline) {
        if (quiet) return false;
        return reply.Error("timeout", "Bluetooth operation timed out", ETIMEDOUT);
      }
      pollfd descriptor{socket_fd, events, 0};
      int result = poll(&descriptor, 1, static_cast<int>(std::max<int64_t>(1, std::min<int64_t>(remaining, 100))));
      if (result < 0 && errno == EINTR) continue;
      if (result < 0) return reply.SystemError("Polling RFCOMM socket");
      if (result == 0) continue;
      if (descriptor.revents & events) return true;
      int number = 0;
      socklen_t length = sizeof(number);
      if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, &number, &length) != 0) number = errno;
      if (number == 0) number = ECONNRESET;
      return reply.SystemError("RFCOMM socket closed", number);
    }
  }

  // Check only while idle; never consume protocol bytes or send heartbeat commands.
  void CheckDisconnect() {
    if (socket_fd < 0) return;
    pollfd descriptor{socket_fd, POLLIN, 0};
    if (poll(&descriptor, 1, 0) <= 0) return;
    if (descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) {
      CloseSocket();
    } else if (descriptor.revents & POLLIN) {
      uint8_t byte;
      if (recv(socket_fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0) CloseSocket();
    }
  }

  bool Connect(const std::string& address, Reply& reply) {
    if (!RequireAdapter(reply)) return false;
    sockaddr_rc remote{};
    remote.rc_family = AF_BLUETOOTH;
    remote.rc_channel = 1;
    if (address.size() != 17 || str2ba(address.c_str(), &remote.rc_bdaddr) != 0)
      return reply.Error("invalid_argument", "Bluetooth address must be XX:XX:XX:XX:XX:XX", EINVAL);
    for (size_t index = 0; index < address.size(); ++index) {
      if (index % 3 == 2 ? address[index] != ':' :
          !std::isxdigit(static_cast<unsigned char>(address[index])))
        return reply.Error("invalid_argument", "Bluetooth address must be XX:XX:XX:XX:XX:XX", EINVAL);
    }
    CloseSocket();
    {
      std::lock_guard<std::mutex> lock(socket_mutex);
      socket_fd = socket(AF_BLUETOOTH, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, BTPROTO_RFCOMM);
    }
    if (socket_fd < 0) return reply.SystemError("Creating RFCOMM channel 1 socket");
    int result = connect(socket_fd, reinterpret_cast<sockaddr*>(&remote), sizeof(remote));
    if (result != 0 && errno != EINPROGRESS) return reply.SystemError("Connecting RFCOMM channel 1 to " + address);
    if (result != 0) {
      if (!WaitSocket(POLLOUT, Clock::now() + std::chrono::seconds(10), reply)) return false;
      int number = 0;
      socklen_t length = sizeof(number);
      if (getsockopt(socket_fd, SOL_SOCKET, SO_ERROR, &number, &length) != 0)
        return reply.SystemError("Reading RFCOMM connection result");
      if (number) return reply.SystemError("Connecting RFCOMM channel 1 to " + address, number);
    }
    return true;
  }

  bool Write(const std::vector<uint8_t>& bytes, Clock::time_point deadline, Reply& reply) {
    if (socket_fd < 0) return reply.Error("not_connected", "No Bluetooth printer is connected", ENOTCONN);
    size_t offset = 0;
    while (offset < bytes.size()) {
      if (!WaitSocket(POLLOUT, deadline, reply)) {
        reply.message += " after " + std::to_string(offset) + "/" + std::to_string(bytes.size()) + " bytes written";
        return false;
      }
      ssize_t count = send(socket_fd, bytes.data() + offset, bytes.size() - offset, MSG_NOSIGNAL);
      if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
      if (count <= 0) return reply.SystemError("Writing RFCOMM after " + std::to_string(offset) + " bytes", count == 0 ? ECONNRESET : errno);
      offset += static_cast<size_t>(count);
    }
    return true;
  }

  bool Exchange(const Request& request, Reply& reply) {
    auto deadline = Clock::now() + std::chrono::milliseconds(request.timeout);
    if (!Write(request.bytes, deadline, reply)) return false;
    reply.kind = Reply::kBytes;
    reply.bytes.reserve(request.expected ? static_cast<size_t>(request.expected) : 64);
    auto quiet_deadline = deadline;
    for (;;) {
      bool quiet = request.expected == 0 && !reply.bytes.empty() && quiet_deadline < deadline;
      if (!WaitSocket(POLLIN, quiet ? quiet_deadline : deadline, reply, quiet)) {
        if (quiet && reply.code.empty()) return true;
        reply.message += " after " + std::to_string(reply.bytes.size()) + " bytes received";
        return false;
      }
      uint8_t buffer[1024];
      size_t available = request.expected ? static_cast<size_t>(request.expected) - reply.bytes.size() : sizeof(buffer);
      ssize_t count = recv(socket_fd, buffer, std::min(sizeof(buffer), available), 0);
      if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
      if (count <= 0) return reply.SystemError("Reading RFCOMM response", count == 0 ? ECONNRESET : errno);
      if (reply.bytes.size() + static_cast<size_t>(count) > kReplyLimit)
        return reply.Error("bluetooth_error", "Bluetooth response exceeds 65536 bytes", EMSGSIZE);
      reply.bytes.insert(reply.bytes.end(), buffer, buffer + count);
      if (request.expected && reply.bytes.size() == static_cast<size_t>(request.expected)) return true;
      quiet_deadline = Clock::now() + std::chrono::milliseconds(100);
    }
  }

  bool AdapterState(Reply& reply) {
    g_autoptr(GError) error = nullptr;
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, cancellable, &error);
    if (!bus) return reply.Error("bluetooth_unavailable", "System Bluetooth service is unavailable", error->code);
    g_autoptr(GVariant) result = g_dbus_connection_call_sync(bus, "org.bluez", "/",
        "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", nullptr,
        G_VARIANT_TYPE("(a{oa{sa{sv}}})"), G_DBUS_CALL_FLAGS_NONE, 5000, cancellable, &error);
    if (!result) return reply.Error("bluetooth_unavailable", "BlueZ service is unavailable", error->code);
    reply.kind = Reply::kAdapter;
    g_autoptr(GVariant) objects = g_variant_get_child_value(result, 0);
    GVariantIter iterator;
    g_variant_iter_init(&iterator, objects);
    const gchar* path;
    GVariant* interfaces;
    while (g_variant_iter_next(&iterator, "{&o@a{sa{sv}}}", &path, &interfaces)) {
      GVariant* properties = g_variant_lookup_value(interfaces, "org.bluez.Adapter1", G_VARIANT_TYPE("a{sv}"));
      if (properties) {
        gboolean powered = FALSE;
        reply.available = true;
        g_variant_lookup(properties, "Powered", "b", &powered);
        reply.enabled = reply.enabled || powered;
        g_variant_unref(properties);
      }
      g_variant_unref(interfaces);
    }
    return true;
  }

  bool RequireAdapter(Reply& reply) {
    Reply state;
    if (!AdapterState(state)) { reply = std::move(state); return false; }
    if (!state.available) return reply.Error("bluetooth_unavailable", "No Bluetooth adapter is available", ENODEV);
    if (!state.enabled) return reply.Error("bluetooth_disabled", "Turn on Bluetooth in system settings", ENETDOWN);
    return true;
  }

  bool RequestEnable(Reply& reply) {
    Reply state;
    if (!AdapterState(state)) { reply = std::move(state); return false; }
    if (!state.available) return reply.Error("bluetooth_unavailable", "No Bluetooth adapter is available", ENODEV);
    reply.kind = Reply::kText;
    if (state.enabled) { reply.text = "enabled"; return true; }
    // Launch a desktop control panel, never write BlueZ Powered or rfkill state.
    const char* programs[] = {"blueman-manager", "gnome-control-center", "systemsettings"};
    const char* panels[] = {nullptr, "bluetooth", "kcm_bluetooth"};
    for (size_t index = 0; index < 3; ++index) {
      g_autofree gchar* executable = g_find_program_in_path(programs[index]);
      if (!executable) continue;
      gchar* arguments[] = {executable, const_cast<gchar*>(panels[index]), nullptr};
      g_autoptr(GError) error = nullptr;
      if (g_spawn_async(nullptr, arguments, nullptr, G_SPAWN_DEFAULT, nullptr, nullptr, nullptr, &error)) {
        reply.text = "settings_opened";
        return true;
      }
    }
    return reply.Error("settings_unavailable", "Open your desktop Bluetooth settings to enable Bluetooth", ENOENT);
  }

  bool Devices(Reply& reply) {
    if (!RequireAdapter(reply)) return false;
    g_autoptr(GError) error = nullptr;
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, cancellable, &error);
    if (!bus) return reply.Error("bluetooth_error", "Connecting to system D-Bus: " + std::string(error->message), error->code);
    g_autoptr(GVariant) result = g_dbus_connection_call_sync(bus, "org.bluez", "/",
        "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", nullptr,
        G_VARIANT_TYPE("(a{oa{sa{sv}}})"), G_DBUS_CALL_FLAGS_NONE, 5000, cancellable, &error);
    if (!result) return reply.Error("bluetooth_error", "Enumerating BlueZ devices: " + std::string(error->message), error->code);
    reply.kind = Reply::kDevices;
    g_autoptr(GVariant) objects = g_variant_get_child_value(result, 0);
    GVariantIter iterator;
    g_variant_iter_init(&iterator, objects);
    const gchar* object_path;
    GVariant* interfaces;
    while (g_variant_iter_next(&iterator, "{&o@a{sa{sv}}}", &object_path, &interfaces)) {
      GVariant* properties = g_variant_lookup_value(interfaces, "org.bluez.Device1", G_VARIANT_TYPE("a{sv}"));
      if (properties) {
        const gchar* address = nullptr;
        const gchar* name = nullptr;
        g_variant_lookup(properties, "Address", "&s", &address);
        g_variant_lookup(properties, "Alias", "&s", &name);
        if (!name) g_variant_lookup(properties, "Name", "&s", &name);
        if (address && std::none_of(reply.devices.begin(), reply.devices.end(), [address](const auto& entry) { return entry.second == address; }))
          reply.devices.emplace_back(name ? name : address, address);
        g_variant_unref(properties);
      }
      g_variant_unref(interfaces);
    }
    std::sort(reply.devices.begin(), reply.devices.end());
    return true;
  }

  bool SaveText(const std::string& filename, const std::string& json, Reply& reply) {
    if (g_mkdir_with_parents(template_directory.c_str(), 0700) != 0)
      return reply.Error("file_error", "Creating template directory: " + std::string(std::strerror(errno)), errno);
    std::string temporary = template_directory + "/.templates-XXXXXX";
    std::vector<char> path(temporary.begin(), temporary.end());
    path.push_back('\0');
    int fd = g_mkstemp_full(path.data(), O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return reply.Error("file_error", "Creating temporary templates file: " + std::string(std::strerror(errno)), errno);
    bool success = true;
    size_t offset = 0;
    while (offset < json.size()) {
      ssize_t count = write(fd, json.data() + offset, json.size() - offset);
      if (count < 0 && errno == EINTR) continue;
      if (count <= 0) {
        int number = count == 0 ? EIO : errno;
        success = reply.Error("file_error", "Writing templates: " + std::string(std::strerror(number)), number);
        break;
      }
      offset += static_cast<size_t>(count);
    }
    if (success && fsync(fd) != 0) success = reply.Error("file_error", "Flushing templates: " + std::string(std::strerror(errno)), errno);
    if (close(fd) != 0 && success) success = reply.Error("file_error", "Closing templates: " + std::string(std::strerror(errno)), errno);
    if (success && rename(path.data(), (template_directory + "/" + filename).c_str()) != 0)
      success = reply.Error("file_error", "Replacing templates: " + std::string(std::strerror(errno)), errno);
    if (!success) unlink(path.data());
    if (success) {
      int directory = open(template_directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
      if (directory < 0) return reply.Error("file_error", "Opening template directory: " + std::string(std::strerror(errno)), errno);
      if (fsync(directory) != 0) success = reply.Error("file_error", "Flushing template directory: " + std::string(std::strerror(errno)), errno);
      close(directory);
    }
    return success;
  }

  bool LastPrinterAddress(Reply& reply) {
    if (!ReadFile(template_directory + "/last-printer-address", false, true, reply)) return false;
    if (reply.text == "[]") { reply = Reply{}; return true; }
    bdaddr_t address;
    if (reply.text.size() != 17 || str2ba(reply.text.c_str(), &address) != 0)
      return reply.Error("storage_error", "Saved printer address is invalid", EINVAL);
    return true;
  }

  bool SaveLastPrinterAddress(const std::string& address, Reply& reply) {
    bdaddr_t parsed;
    if (address.size() != 17 || str2ba(address.c_str(), &parsed) != 0)
      return reply.Error("invalid_address", "Invalid Bluetooth address", EINVAL);
    return SaveText("last-printer-address", address, reply);
  }

  void Run() {
    for (;;) {
      Request request;
      {
        std::unique_lock<std::mutex> lock(queue_mutex);
        if (socket_fd >= 0) {
          ready.wait_for(lock, std::chrono::milliseconds(500), [this] { return stopping.load() || !queue.empty(); });
        } else {
          ready.wait(lock, [this] { return stopping.load() || !queue.empty(); });
        }
        if (stopping.load()) break;
        if (queue.empty()) { lock.unlock(); CheckDisconnect(); continue; }
        request = std::move(queue.front());
        queue.pop_front();
      }
      Reply reply;
      bool success = true;
      if (request.method == "devices") success = Devices(reply);
      else if (request.method == "connect") success = Connect(request.text, reply);
      else if (request.method == "disconnect") CloseSocket();
      else if (request.method == "write") success = Write(request.bytes, Clock::now() + std::chrono::seconds(10), reply);
      else if (request.method == "exchange") success = Exchange(request, reply);
      else if (request.method == "pickImage") success = ReadFile(request.path, true, false, reply);
      else if (request.method == "loadTemplates") success = ReadFile(template_directory + "/templates.json", false, true, reply);
      else if (request.method == "saveTemplates") success = SaveText("templates.json", request.text, reply);
      else if (request.method == "readState") success = ReadFile(template_directory + "/" + request.path, false, true, reply, true);
      else if (request.method == "writeState") success = SaveText(request.path, request.text, reply);
      else if (request.method == "lastPrinterAddress") success = LastPrinterAddress(reply);
      else if (request.method == "saveLastPrinterAddress") success = SaveLastPrinterAddress(request.text, reply);
      else if (request.method == "adapterState") success = AdapterState(reply);
      else if (request.method == "requestEnableBluetooth") success = RequestEnable(reply);
      if (!success && (request.method == "connect" || request.method == "write" || request.method == "exchange")) CloseSocket();
      Complete(std::move(request.call), std::move(reply));
    }
    CloseSocket();
    std::lock_guard<std::mutex> lock(queue_mutex);
    queue.clear();
  }
};

DeviceBridge::DeviceBridge(FlBinaryMessenger* messenger, GtkWindow* window)
    : impl_(new Impl(messenger, window)) {}
DeviceBridge::~DeviceBridge() = default;
