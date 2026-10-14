#ifndef RUNNER_DEVICE_BRIDGE_H_
#define RUNNER_DEVICE_BRIDGE_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <memory>

class DeviceBridge {
 public:
  static constexpr UINT kCompletionMessage = WM_APP + 0x110;
  DeviceBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~DeviceBridge();
  DeviceBridge(const DeviceBridge&) = delete;
  DeviceBridge& operator=(const DeviceBridge&) = delete;
  // Called by the owning runner on its UI thread, before Flutter's handler.
  void DispatchCompletions();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_DEVICE_BRIDGE_H_
