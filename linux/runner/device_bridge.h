#ifndef RUNNER_DEVICE_BRIDGE_H_
#define RUNNER_DEVICE_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <memory>

// Owns the desktop channel and a single serialized I/O worker. Destroy before
// the Flutter view so pending replies cannot outlive the engine.
class DeviceBridge {
 public:
  DeviceBridge(FlBinaryMessenger* messenger, GtkWindow* window);
  ~DeviceBridge();
  DeviceBridge(const DeviceBridge&) = delete;
  DeviceBridge& operator=(const DeviceBridge&) = delete;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_DEVICE_BRIDGE_H_
