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

  // Desktop simulated picture-in-picture channel, matching the Android side
  // 'com.zy.player/pip'. Dart calls enterPip/exitPip; the native side turns the
  // main window into a top-most borderless floating window and emits the
  // onPipModeChanged event so Flutter can hide/restore its UI (video only).
  auto messenger = flutter_controller_->engine()->messenger();
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
          Win32Window::Trace("channel pip.enterPip");
          this->EnterPip(aspect);
          this->pip_channel_->InvokeMethod(
              "onPipModeChanged",
              std::make_unique<flutter::EncodableValue>(true));
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "exitPip") {
          Win32Window::Trace("channel pip.exitPip");
          this->ExitPip();
          this->pip_channel_->InvokeMethod(
              "onPipModeChanged",
              std::make_unique<flutter::EncodableValue>(false));
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });

  // Desktop real window fullscreen channel, matching the Dart side
  // 'com.zy.player/window'. Handles enterFullscreen/exitFullscreen to make the
  // app window borderless and fill the whole monitor (covering the taskbar).
  auto window_messenger = flutter_controller_->engine()->messenger();
  window_channel_ = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      window_messenger, "com.zy.player/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "enterFullscreen") {
          Win32Window::Trace("channel window.enterFullscreen");
          this->EnterFullscreen();
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "exitFullscreen") {
          Win32Window::Trace("channel window.exitFullscreen");
          this->ExitFullscreen();
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });

  Win32Window::Trace("OnCreate: channels ready");
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
      if (message == WM_SIZE) {
        Win32Window::Trace("  WM_SIZE consumed by engine");
      }
      return *result;
    }
  }

  if (message == WM_SIZE) {
    Win32Window::Trace("  WM_SIZE falls through to runner");
  }

  switch (message) {
    case WM_CLOSE:
      // Closing the window (title-bar X / Alt+F4) while in simulated PiP or in
      // real fullscreen must not quit the app: the window has to be restored
      // first, and Flutter has to be told so that its UI leaves the special
      // mode (otherwise the app is left showing video only, with no controls to
      // get back, which looks like a freeze).
      //
      // The restore itself is always initiated from Dart (see
      // 'onPipExitRequested' / 'onFullscreenExitRequested'): Dart temporarily
      // detaches the video texture around the window change, which avoids the
      // engine / video-plugin deadlock that used to freeze the app here.
      if (IsInPip()) {
        Win32Window::Trace("WM_CLOSE -> ask Dart to exit PiP");
        if (pip_channel_) {
          pip_channel_->InvokeMethod(
              "onPipExitRequested",
              std::make_unique<flutter::EncodableValue>(true));
        }
        return 0;
      }
      if (IsFullscreen()) {
        Win32Window::Trace("WM_CLOSE -> ask Dart to exit fullscreen");
        if (window_channel_) {
          window_channel_->InvokeMethod(
              "onFullscreenExitRequested",
              std::make_unique<flutter::EncodableValue>(true));
        }
        return 0;
      }
      break;

    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
