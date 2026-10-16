#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Windows 桌面端「模拟画中画」通道：与 Android 端 'com.zy.player/pip' 对应。
  // Dart 调 enterPip/exitPip，原生把主窗变为置顶无边框小浮窗，并回传
  // onPipModeChanged 事件，驱动 Flutter 隐藏/恢复全部 UI（只留纯播放画面）。
  auto messenger = flutter_controller_->engine()->GetBinaryMessenger();
  pip_channel_ = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.zy.player/pip",
      &flutter::StandardMethodCodec::GetInstance());
  pip_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "enterPip") {
          double aspect = 16.0 / 9.0;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            if (auto it = args->find(flutter::EncodableValue("aspect"));
                it != args->end()) {
              if (const auto* d = std::get_if<double>(&it->second)) {
                aspect = *d;
              }
            }
          }
          this->EnterPip(aspect);
          this->pip_channel_->InvokeMethod(
              "onPipModeChanged",
              std::make_unique<flutter::EncodableValue>(true));
          result->Success(std::make_unique<flutter::EncodableValue>(true));
        } else if (call.method_name() == "exitPip") {
          this->ExitPip();
          this->pip_channel_->InvokeMethod(
              "onPipModeChanged",
              std::make_unique<flutter::EncodableValue>(false));
          result->Success(std::make_unique<flutter::EncodableValue>(true));
        } else {
          result->NotImplemented();
        }
      });

  // 桌面端「真正窗口全屏」通道：与 Dart 端 'com.zy.player/window' 对应，
  // 处理 enterFullscreen/exitFullscreen，把应用窗口铺满整个显示器（无边框、盖任务栏）。
  auto window_messenger = flutter_controller_->engine()->GetBinaryMessenger();
  window_channel_ = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      window_messenger, "com.zy.player/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "enterFullscreen") {
          this->EnterFullscreen();
          result->Success(std::make_unique<flutter::EncodableValue>(true));
        } else if (call.method_name() == "exitFullscreen") {
          this->ExitFullscreen();
          result->Success(std::make_unique<flutter::EncodableValue>(true));
        } else {
          result->NotImplemented();
        }
      });

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
