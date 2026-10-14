// winsock2 must precede windows.h and Flutter's Windows wrapper headers.
#include <winsock2.h>
#include <ws2bth.h>
#include "device_bridge.h"

#include <bthsdpdef.h>
#include <bluetoothapis.h>
#include <commdlg.h>
#include <shlobj.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <climits>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <iterator>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {
constexpr size_t kImageLimit = 16 * 1024 * 1024;
constexpr size_t kReplyLimit = 64 * 1024;
using Clock = std::chrono::steady_clock;
using Value = flutter::EncodableValue;
using Result = std::shared_ptr<flutter::MethodResult<Value>>;

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string output(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), &output[0], size, nullptr, nullptr);
  return output;
}

std::string SystemMessage(DWORD error) {
  wchar_t* buffer = nullptr;
  DWORD size = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
      FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, error, 0,
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  std::string message = size ? Utf8(std::wstring(buffer, size)) : "Unknown system error";
  if (buffer) LocalFree(buffer);
  while (!message.empty() && (message.back() == '\r' || message.back() == '\n')) message.pop_back();
  return message + " (Windows error " + std::to_string(error) + ")";
}

struct Reply {
  Value value;
  std::string code;
  std::string message;
  DWORD os_error = 0;
  bool Error(const char* error_code, const std::string& description, DWORD number) {
    code = error_code;
    message = description;
    os_error = number;
    return false;
  }
  bool SocketError(const std::string& operation, int number = WSAGetLastError()) {
    return Error("bluetooth_error", operation + ": " + SystemMessage(static_cast<DWORD>(number)), static_cast<DWORD>(number));
  }
  bool FileError(const std::string& operation, DWORD number = GetLastError()) {
    return Error("file_error", operation + ": " + SystemMessage(number), number);
  }
};

void Respond(const Result& result, Reply reply) {
  if (reply.code.empty()) result->Success(reply.value);
  else result->Error(reply.code, reply.message, Value(static_cast<int64_t>(reply.os_error)));
}

struct Request {
  Result result;
  std::string method;
  std::string text;
  std::wstring path;
  std::vector<uint8_t> bytes;
  int expected = 0;
  int timeout = 3000;
};

const Value* Argument(const Value* args, const char* name) {
  const auto* map = args ? std::get_if<flutter::EncodableMap>(args) : nullptr;
  if (!map) return nullptr;
  auto value = map->find(Value(name));
  return value == map->end() ? nullptr : &value->second;
}

bool Integer(const Value* value, int64_t& output) {
  if (!value) return false;
  if (const auto* integer = std::get_if<int32_t>(value)) { output = *integer; return true; }
  if (const auto* integer = std::get_if<int64_t>(value)) { output = *integer; return true; }
  return false;
}

bool ParseAddress(const std::string& text, BTH_ADDR& address) {
  if (text.size() != 17) return false;
  address = 0;
  for (size_t index = 0; index < text.size(); ++index) {
    if (index % 3 == 2) { if (text[index] != ':') return false; continue; }
    char digit = text[index];
    int nibble = digit >= '0' && digit <= '9' ? digit - '0' :
                 digit >= 'a' && digit <= 'f' ? digit - 'a' + 10 :
                 digit >= 'A' && digit <= 'F' ? digit - 'A' + 10 : -1;
    if (nibble < 0) return false;
    address = (address << 4) | static_cast<BTH_ADDR>(nibble);
  }
  return true;
}

std::string Address(BTH_ADDR address) {
  char text[18];
  std::snprintf(text, sizeof(text), "%02X:%02X:%02X:%02X:%02X:%02X",
      static_cast<unsigned>((address >> 40) & 255), static_cast<unsigned>((address >> 32) & 255),
      static_cast<unsigned>((address >> 24) & 255), static_cast<unsigned>((address >> 16) & 255),
      static_cast<unsigned>((address >> 8) & 255), static_cast<unsigned>(address & 255));
  return text;
}

struct FileHandle {
  HANDLE value = INVALID_HANDLE_VALUE;
  explicit FileHandle(HANDLE file) : value(file) {}
  ~FileHandle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  FileHandle(const FileHandle&) = delete;
  FileHandle& operator=(const FileHandle&) = delete;
};

bool ReadFileContents(const std::wstring& path, bool image, bool missing_ok, Reply& reply) {
  FileHandle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
  if (file.value == INVALID_HANDLE_VALUE) {
    DWORD number = GetLastError();
    if (missing_ok && (number == ERROR_FILE_NOT_FOUND || number == ERROR_PATH_NOT_FOUND)) {
      reply.value = Value("[]");
      return true;
    }
    return reply.FileError("Opening file", number);
  }
  LARGE_INTEGER size;
  if (!GetFileSizeEx(file.value, &size)) return reply.FileError("Reading file size");
  if (GetFileType(file.value) != FILE_TYPE_DISK || size.QuadPart < 0 ||
      (image && size.QuadPart > static_cast<LONGLONG>(kImageLimit)))
    return reply.Error("file_error", "Select a regular image file no larger than 16 MiB", ERROR_FILE_TOO_LARGE);
  std::vector<uint8_t> contents;
  contents.reserve(static_cast<size_t>(size.QuadPart));
  uint8_t buffer[8192];
  for (;;) {
    DWORD count = 0;
    if (!ReadFile(file.value, buffer, static_cast<DWORD>(sizeof(buffer)), &count, nullptr)) return reply.FileError("Reading file");
    if (count == 0) break;
    if (image && contents.size() + count > kImageLimit)
      return reply.Error("file_error", "Image exceeds the 16 MiB limit", ERROR_FILE_TOO_LARGE);
    contents.insert(contents.end(), buffer, buffer + count);
  }
  if (image) reply.value = std::move(contents);
  else {
    std::string text(contents.begin(), contents.end());
    if (!text.empty() && (text.size() > static_cast<size_t>(INT_MAX) ||
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0) == 0))
      return reply.Error("file_error", "Saved templates are not valid UTF-8", ERROR_NO_UNICODE_TRANSLATION);
    reply.value = std::move(text);
  }
  return true;
}
}  // namespace

struct DeviceBridge::Impl {
  HWND window;
  std::unique_ptr<flutter::MethodChannel<Value>> channel;
  int winsock_error = 0;
  std::atomic<bool> stopping{false};
  std::mutex queue_mutex;
  std::condition_variable ready;
  std::deque<Request> queue;
  std::mutex completion_mutex;
  std::deque<std::pair<Result, Reply>> completions;
  std::mutex socket_mutex;
  SOCKET socket_handle = INVALID_SOCKET;
  std::thread worker;
  std::atomic<bool> picker_open{false};
  std::atomic<HWND> picker_window{nullptr};
  std::thread picker;
  std::wstring template_directory;

  Impl(flutter::BinaryMessenger* messenger, HWND parent) : window(parent) {
    WSADATA data{};
    winsock_error = WSAStartup(MAKEWORD(2, 2), &data);
    channel = std::make_unique<flutter::MethodChannel<Value>>(messenger,
        "d110_studio/device", &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
        std::unique_ptr<flutter::MethodResult<Value>> result) { Handle(call, std::move(result)); });
    worker = std::thread([this] { Run(); });
  }

  ~Impl() {
    channel->SetMethodCallHandler(nullptr);
    stopping.store(true);
    HWND dialog = picker_window.load();
    if (dialog) PostMessageW(dialog, WM_COMMAND, IDCANCEL, 0);
    {
      std::lock_guard<std::mutex> lock(socket_mutex);
      if (socket_handle != INVALID_SOCKET) shutdown(socket_handle, SD_BOTH);
    }
    ready.notify_one();
    worker.join();
    if (picker.joinable()) picker.join();
    // Results are destroyed on the UI thread before the Flutter engine.
    completions.clear();
    queue.clear();
    if (winsock_error == 0) WSACleanup();
  }

  void Enqueue(Request request) {
    {
      std::lock_guard<std::mutex> lock(queue_mutex);
      queue.push_back(std::move(request));
    }
    ready.notify_one();
  }

  void Complete(Result result, Reply reply) {
    {
      std::lock_guard<std::mutex> lock(completion_mutex);
      completions.emplace_back(std::move(result), std::move(reply));
    }
    PostMessageW(window, DeviceBridge::kCompletionMessage, 0, 0);
  }

  void Dispatch() {
    std::deque<std::pair<Result, Reply>> pending;
    {
      std::lock_guard<std::mutex> lock(completion_mutex);
      pending.swap(completions);
    }
    for (auto& completion : pending) Respond(completion.first, std::move(completion.second));
  }

  void Handle(const flutter::MethodCall<Value>& call,
              std::unique_ptr<flutter::MethodResult<Value>> result) {
    Request request;
    request.result = Result(std::move(result));
    request.method = call.method_name();
    Reply error;
    const Value* args = call.arguments();
    if (request.method == "connect") {
      const Value* value = Argument(args, "address");
      const auto* address = value ? std::get_if<std::string>(value) : nullptr;
      if (!address) {
        error.Error("invalid_argument", "connect requires an address string", ERROR_INVALID_PARAMETER);
        Respond(request.result, std::move(error));
        return;
      }
      request.text = *address;
    } else if (request.method == "write" || request.method == "exchange") {
      const Value* value = Argument(args, "bytes");
      const auto* bytes = value ? std::get_if<std::vector<uint8_t>>(value) : nullptr;
      if (!bytes) {
        error.Error("invalid_argument", "bytes must be a Uint8List", ERROR_INVALID_PARAMETER);
        Respond(request.result, std::move(error));
        return;
      }
      request.bytes = *bytes;
      if (request.method == "exchange") {
        int64_t expected = 0, timeout = 0;
        if (!Integer(Argument(args, "expectedLength"), expected) || !Integer(Argument(args, "timeoutMs"), timeout) ||
            expected < 0 || expected > static_cast<int64_t>(kReplyLimit) || timeout < 1 || timeout > 30000) {
          error.Error("invalid_argument", "exchange requires expectedLength 0..65536 and timeoutMs 1..30000", ERROR_INVALID_PARAMETER);
          Respond(request.result, std::move(error));
          return;
        }
        request.expected = static_cast<int>(expected);
        request.timeout = static_cast<int>(timeout);
      }
    } else if (request.method == "saveTemplates") {
      const Value* value = Argument(args, "json");
      const auto* json = value ? std::get_if<std::string>(value) : nullptr;
      if (!json) {
        error.Error("invalid_argument", "saveTemplates requires a JSON string", ERROR_INVALID_PARAMETER);
        Respond(request.result, std::move(error));
        return;
      }
      request.text = *json;
    } else if (request.method == "pickImage") {
      PickImage(std::move(request));
      return;
    } else if (request.method != "devices" && request.method != "disconnect" && request.method != "loadTemplates") {
      request.result->NotImplemented();
      return;
    }
    Enqueue(std::move(request));
  }

  static UINT_PTR CALLBACK PickerHook(HWND dialog, UINT message, WPARAM, LPARAM parameter) {
    if (message == WM_INITDIALOG) {
      auto* options = reinterpret_cast<OPENFILENAMEW*>(parameter);
      auto* self = reinterpret_cast<Impl*>(options->lCustData);
      HWND top_level = GetParent(dialog);
      self->picker_window.store(top_level);
      if (self->stopping.load()) PostMessageW(top_level, WM_COMMAND, IDCANCEL, 0);
    }
    return 0;
  }

  void PickImage(Request request) {
    if (picker_open.exchange(true)) {
      Reply reply;
      reply.Error("busy", "An image chooser is already open", ERROR_BUSY);
      Respond(request.result, std::move(reply));
      return;
    }
    if (picker.joinable()) picker.join();
    picker = std::thread([this, request = std::move(request)]() mutable {
      Reply reply;
      HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
      if (FAILED(apartment)) {
        reply.FileError("Initializing image chooser", static_cast<DWORD>(apartment));
        Complete(std::move(request.result), std::move(reply));
        picker_open.store(false);
        return;
      }
      std::vector<wchar_t> filename(32768, L'\0');
      OPENFILENAMEW dialog{};
      dialog.lStructSize = sizeof(dialog);
      // The dialog has its own UI thread. A cross-thread modal owner would
      // synchronously message the runner during teardown and deadlock its join.
      dialog.lpstrFile = filename.data();
      dialog.nMaxFile = static_cast<DWORD>(filename.size());
      dialog.lpstrFilter = L"Images\0*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp\0All files\0*.*\0\0";
      dialog.lpstrTitle = L"Choose label image";
      dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR |
                     OFN_EXPLORER | OFN_ENABLEHOOK;
      dialog.lpfnHook = PickerHook;
      dialog.lCustData = reinterpret_cast<LPARAM>(this);
      BOOL selected = stopping.load() ? FALSE : GetOpenFileNameW(&dialog);
      DWORD number = selected ? 0 : CommDlgExtendedError();
      picker_window.store(nullptr);
      CoUninitialize();
      if (stopping.load()) {
        reply.Error("cancelled", "Application is closing", ERROR_CANCELLED);
        Complete(std::move(request.result), std::move(reply));
      } else if (!selected) {
        if (number) reply.Error("file_error", "Opening image chooser failed (common dialog error " + std::to_string(number) + ")", number);
        Complete(std::move(request.result), std::move(reply));
      } else {
        request.path = filename.data();
        Enqueue(std::move(request));
      }
      picker_open.store(false);
    });
  }

  void CloseSocket() {
    std::lock_guard<std::mutex> lock(socket_mutex);
    if (socket_handle != INVALID_SOCKET) {
      shutdown(socket_handle, SD_BOTH);
      closesocket(socket_handle);
      socket_handle = INVALID_SOCKET;
    }
  }

  bool WaitSocket(bool writing, Clock::time_point deadline, Reply& reply, bool quiet = false) {
    for (;;) {
      if (stopping.load()) return reply.Error("cancelled", "Application is closing", ERROR_CANCELLED);
      auto now = Clock::now();
      auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count();
      if (now >= deadline) {
        if (quiet) return false;
        return reply.Error("timeout", "Bluetooth operation timed out", WSAETIMEDOUT);
      }
      fd_set activity, errors;
      FD_ZERO(&activity);
      FD_ZERO(&errors);
      FD_SET(socket_handle, &activity);
      FD_SET(socket_handle, &errors);
      timeval timeout{};
      timeout.tv_usec = static_cast<long>(std::max<int64_t>(1, std::min<int64_t>(remaining, 100)) * 1000);
      int count = select(0, writing ? nullptr : &activity, writing ? &activity : nullptr, &errors, &timeout);
      if (count == SOCKET_ERROR) return reply.SocketError("Waiting for RFCOMM socket");
      if (count == 0) continue;
      if (FD_ISSET(socket_handle, &errors)) {
        int number = 0;
        int size = sizeof(number);
        if (getsockopt(socket_handle, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&number), &size) == SOCKET_ERROR)
          return reply.SocketError("Reading RFCOMM socket error");
        return reply.SocketError("RFCOMM socket failed", number ? number : WSAECONNRESET);
      }
      if (FD_ISSET(socket_handle, &activity)) return true;
    }
  }

  bool Connect(const std::string& address, Reply& reply) {
    BTH_ADDR parsed;
    if (!ParseAddress(address, parsed))
      return reply.Error("invalid_argument", "Bluetooth address must be XX:XX:XX:XX:XX:XX", ERROR_INVALID_PARAMETER);
    CloseSocket();
    if (winsock_error) return reply.SocketError("Starting Winsock", winsock_error);
    {
      std::lock_guard<std::mutex> lock(socket_mutex);
      socket_handle = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    }
    if (socket_handle == INVALID_SOCKET) return reply.SocketError("Creating RFCOMM channel 1 socket");
    u_long nonblocking = 1;
    if (ioctlsocket(socket_handle, FIONBIO, &nonblocking) == SOCKET_ERROR)
      return reply.SocketError("Setting RFCOMM socket nonblocking");
    SOCKADDR_BTH remote{};
    remote.addressFamily = AF_BTH;
    remote.btAddr = parsed;
    remote.port = 1;
    int result = connect(socket_handle, reinterpret_cast<sockaddr*>(&remote), static_cast<int>(sizeof(remote)));
    if (result == SOCKET_ERROR) {
      int number = WSAGetLastError();
      if (number != WSAEWOULDBLOCK && number != WSAEINPROGRESS)
        return reply.SocketError("Connecting RFCOMM channel 1 to " + address, number);
      if (!WaitSocket(true, Clock::now() + std::chrono::seconds(10), reply)) return false;
      number = 0;
      int size = sizeof(number);
      if (getsockopt(socket_handle, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&number), &size) == SOCKET_ERROR)
        return reply.SocketError("Reading RFCOMM connection result");
      if (number) return reply.SocketError("Connecting RFCOMM channel 1 to " + address, number);
    }
    return true;
  }

  bool Write(const std::vector<uint8_t>& bytes, Clock::time_point deadline, Reply& reply) {
    if (socket_handle == INVALID_SOCKET)
      return reply.Error("not_connected", "No Bluetooth printer is connected", WSAENOTCONN);
    size_t offset = 0;
    while (offset < bytes.size()) {
      if (!WaitSocket(true, deadline, reply)) {
        reply.message += " after " + std::to_string(offset) + "/" + std::to_string(bytes.size()) + " bytes written";
        return false;
      }
      int count = send(socket_handle, reinterpret_cast<const char*>(bytes.data() + offset),
          static_cast<int>(std::min<size_t>(bytes.size() - offset, 65536)), 0);
      if (count == SOCKET_ERROR) {
        int number = WSAGetLastError();
        if (number == WSAEWOULDBLOCK || number == WSAEINTR) continue;
        return reply.SocketError("Writing RFCOMM after " + std::to_string(offset) + " bytes", number);
      }
      if (count == 0) return reply.SocketError("Writing RFCOMM", WSAECONNRESET);
      offset += static_cast<size_t>(count);
    }
    return true;
  }

  bool Exchange(const Request& request, Reply& reply) {
    auto deadline = Clock::now() + std::chrono::milliseconds(request.timeout);
    if (!Write(request.bytes, deadline, reply)) return false;
    std::vector<uint8_t> bytes;
    bytes.reserve(request.expected ? static_cast<size_t>(request.expected) : 64);
    auto quiet_deadline = deadline;
    for (;;) {
      bool quiet = request.expected == 0 && !bytes.empty() && quiet_deadline < deadline;
      if (!WaitSocket(false, quiet ? quiet_deadline : deadline, reply, quiet)) {
        if (quiet && reply.code.empty()) { reply.value = std::move(bytes); return true; }
        reply.message += " after " + std::to_string(bytes.size()) + " bytes received";
        return false;
      }
      uint8_t buffer[1024];
      size_t available = request.expected ? static_cast<size_t>(request.expected) - bytes.size() : sizeof(buffer);
      int count = recv(socket_handle, reinterpret_cast<char*>(buffer), static_cast<int>(std::min(sizeof(buffer), available)), 0);
      if (count == SOCKET_ERROR) {
        int number = WSAGetLastError();
        if (number == WSAEWOULDBLOCK || number == WSAEINTR) continue;
        return reply.SocketError("Reading RFCOMM response", number);
      }
      if (count == 0) return reply.SocketError("Reading RFCOMM response", WSAECONNRESET);
      if (bytes.size() + static_cast<size_t>(count) > kReplyLimit)
        return reply.Error("bluetooth_error", "Bluetooth response exceeds 65536 bytes", WSAEMSGSIZE);
      bytes.insert(bytes.end(), buffer, buffer + count);
      if (request.expected && bytes.size() == static_cast<size_t>(request.expected)) {
        reply.value = std::move(bytes);
        return true;
      }
      quiet_deadline = Clock::now() + std::chrono::milliseconds(100);
    }
  }

  bool Devices(Reply& reply) {
    BLUETOOTH_DEVICE_SEARCH_PARAMS search{};
    search.dwSize = sizeof(search);
    search.fReturnAuthenticated = TRUE;
    search.fReturnRemembered = TRUE;
    search.fReturnUnknown = TRUE;
    search.fReturnConnected = TRUE;
    search.fIssueInquiry = TRUE;
    search.cTimeoutMultiplier = 1;  // One bounded 1.28-second inquiry.
    BLUETOOTH_DEVICE_INFO device{};
    device.dwSize = sizeof(device);
    HBLUETOOTH_DEVICE_FIND find = BluetoothFindFirstDevice(&search, &device);
    flutter::EncodableList devices;
    if (!find) {
      DWORD number = GetLastError();
      if (number != ERROR_NO_MORE_ITEMS)
        return reply.Error("bluetooth_error", "Enumerating Bluetooth devices: " + SystemMessage(number), number);
      reply.value = std::move(devices);
      return true;
    }
    for (;;) {
      std::string address = Address(device.Address.ullLong);
      std::string name = Utf8(device.szName);
      if (name.empty()) name = address;
      devices.emplace_back();
      devices.back() = flutter::EncodableMap{
          {Value("name"), Value(name)}, {Value("address"), Value(address)}};
      device = {};
      device.dwSize = sizeof(device);
      if (!BluetoothFindNextDevice(find, &device)) {
        DWORD number = GetLastError();
        BluetoothFindDeviceClose(find);
        if (number != ERROR_NO_MORE_ITEMS)
          return reply.Error("bluetooth_error", "Continuing Bluetooth enumeration: " + SystemMessage(number), number);
        break;
      }
    }
    reply.value = std::move(devices);
    return true;
  }

  bool TemplateDirectory(Reply& reply) {
    if (!template_directory.empty()) return true;
    PWSTR path = nullptr;
    HRESULT result = SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &path);
    if (FAILED(result)) return reply.FileError("Locating LocalAppData", static_cast<DWORD>(result));
    template_directory = std::wstring(path) + L"\\D110 Studio";
    CoTaskMemFree(path);
    return true;
  }

  bool SaveTemplates(const std::string& json, Reply& reply) {
    if (!TemplateDirectory(reply)) return false;
    if (!CreateDirectoryW(template_directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS)
      return reply.FileError("Creating template directory");
    GUID guid;
    HRESULT result = CoCreateGuid(&guid);
    if (FAILED(result)) return reply.FileError("Creating temporary file identifier", static_cast<DWORD>(result));
    wchar_t identifier[40];
    if (StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier))) == 0)
      return reply.FileError("Formatting temporary file identifier", ERROR_INVALID_DATA);
    std::wstring temporary = template_directory + L"\\.templates-" + identifier;
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return reply.FileError("Creating temporary templates file");
    bool success = true;
    size_t offset = 0;
    while (offset < json.size()) {
      DWORD count = 0;
      DWORD length = static_cast<DWORD>(std::min<size_t>(json.size() - offset, 65536));
      if (!WriteFile(file, json.data() + offset, length, &count, nullptr)) {
        success = reply.FileError("Writing templates");
        break;
      }
      if (count == 0) {
        success = reply.FileError("Writing templates", ERROR_WRITE_FAULT);
        break;
      }
      offset += count;
    }
    if (success && !FlushFileBuffers(file)) success = reply.FileError("Flushing templates");
    if (!CloseHandle(file) && success) success = reply.FileError("Closing templates");
    if (success && !MoveFileExW(temporary.c_str(), (template_directory + L"\\templates.json").c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) success = reply.FileError("Replacing templates");
    if (!success) DeleteFileW(temporary.c_str());
    return success;
  }

  void Run() {
    for (;;) {
      Request request;
      {
        std::unique_lock<std::mutex> lock(queue_mutex);
        ready.wait(lock, [this] { return stopping.load() || !queue.empty(); });
        if (stopping.load()) break;
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
      else if (request.method == "pickImage") success = ReadFileContents(request.path, true, false, reply);
      else if (request.method == "loadTemplates") {
        success = TemplateDirectory(reply);
        if (success) success = ReadFileContents(template_directory + L"\\templates.json", false, true, reply);
      } else if (request.method == "saveTemplates") success = SaveTemplates(request.text, reply);
      if (!success && (request.method == "connect" || request.method == "write" || request.method == "exchange")) CloseSocket();
      Complete(std::move(request.result), std::move(reply));
    }
    CloseSocket();
  }
};

DeviceBridge::DeviceBridge(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>(messenger, window)) {}
DeviceBridge::~DeviceBridge() = default;
void DeviceBridge::DispatchCompletions() { impl_->Dispatch(); }
