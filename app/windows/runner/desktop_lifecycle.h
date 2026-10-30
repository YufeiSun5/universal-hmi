#ifndef RUNNER_DESKTOP_LIFECYCLE_H_
#define RUNNER_DESKTOP_LIFECYCLE_H_

#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <optional>
#include <string>

// Owns only desktop instance/tray resources; backend ownership remains in Dart.
class DesktopLifecycle {
 public:
  DesktopLifecycle(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopLifecycle();
  std::optional<LRESULT> Handle(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  bool Initialize(const flutter::EncodableMap& arguments);
  bool AddTray();
  void Open();
  void Hide();
  void Exit();
  void Menu();
  HWND window_;
  HANDLE instance_mutex_ = nullptr;
  HANDLE bare_mutex_ = nullptr;
  std::wstring property_;
  std::wstring role_;
  bool initialized_ = false;
  bool exit_approved_ = false;
  bool tray_added_ = false;
  bool hidden_maximized_ = false;
  UINT taskbar_created_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
