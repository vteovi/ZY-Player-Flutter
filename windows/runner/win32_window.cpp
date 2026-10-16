#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    case WM_CLOSE:
      // In simulated PiP or real fullscreen, closing the window (Alt+F4 or the
      // title-bar X) must restore the normal window instead of quitting the app.
      if (in_pip_) {
        ExitPip();
        return 0;
      }
      if (in_fullscreen_) {
        ExitFullscreen();
        return 0;
      }
      break;

    case kMsgApplyPip:
      if (pending_pip_ == PipAction::kEnter) {
        ApplyPipEnter(pending_pip_aspect_);
      } else if (pending_pip_ == PipAction::kExit) {
        ApplyPipExit();
      }
      pending_pip_ = PipAction::kNone;
      return 0;

    case kMsgApplyFs:
      if (pending_fs_ == FsAction::kEnter) {
        ApplyFullscreenEnter();
      } else if (pending_fs_ == FsAction::kExit) {
        ApplyFullscreenExit();
      }
      pending_fs_ = FsAction::kNone;
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}

void Win32Window::EnterPip(double aspect) {
  if (in_pip_ || !window_handle_) {
    return;
  }
  // Save the current style and position/size (screen physical pixels) so they
  // can be restored exactly on exit.
  saved_style_ = static_cast<DWORD>(GetWindowLongPtr(window_handle_, GWL_STYLE));
  GetWindowRect(window_handle_, &saved_rect_);
  pending_pip_aspect_ = aspect;
  in_pip_ = true;
  // Defer the actual style/size change to the message loop (see ApplyPipEnter).
  PostMessage(window_handle_, kMsgApplyPip, 0, 0);
}

void Win32Window::ExitPip() {
  if (!in_pip_ || !window_handle_) {
    return;
  }
  in_pip_ = false;
  PostMessage(window_handle_, kMsgApplyPip, 0, 0);
}

void Win32Window::ApplyPipEnter(double aspect) {
  if (!window_handle_) {
    return;
  }
  HMONITOR monitor = MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale = dpi / 96.0;
  int w = static_cast<int>(360 * scale);
  double a = (aspect > 0.1 && aspect < 10.0) ? aspect : (16.0 / 9.0);
  int h = static_cast<int>(w / a);

  // A real, complete title bar (WS_CAPTION) gives native drag + a working
  // close button; WS_THICKFRAME keeps resizable edges, WS_SYSMENU the system
  // menu. This avoids the broken "half title bar" that a WS_POPUP + WS_SYSMENU
  // combo draws, and is fully movable / restorable / closable.
  SetWindowLongPtr(window_handle_, GWL_STYLE,
                   WS_CAPTION | WS_THICKFRAME | WS_SYSMENU);
  // Force the non-client frame to be recomputed (no leftover caption pixels).
  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  GetMonitorInfo(monitor, &mi);
  int x = mi.rcWork.right - w - 24;
  int y = mi.rcWork.bottom - h - 24;
  SetWindowPos(window_handle_, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
}

void Win32Window::ApplyPipExit() {
  if (!window_handle_) {
    return;
  }
  SetWindowLongPtr(window_handle_, GWL_STYLE, saved_style_);
  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  SetWindowPos(window_handle_, HWND_NOTOPMOST, saved_rect_.left,
               saved_rect_.top, saved_rect_.right - saved_rect_.left,
               saved_rect_.bottom - saved_rect_.top, SWP_NOACTIVATE);
}

bool Win32Window::IsInPip() const {
  return in_pip_;
}

void Win32Window::EnterFullscreen() {
  if (in_fullscreen_ || !window_handle_) {
    return;
  }
  // If currently in simulated PiP, exit the floating window first; the two
  // states are mutually exclusive.
  if (in_pip_) {
    ExitPip();
  }
  saved_fs_style_ =
      static_cast<DWORD>(GetWindowLongPtr(window_handle_, GWL_STYLE));
  GetWindowRect(window_handle_, &saved_fs_rect_);
  in_fullscreen_ = true;
  // Defer the actual style/size change to the message loop (see
  // ApplyFullscreenEnter) to avoid the WM_SIZE re-entrancy deadlock that made
  // the window "freeze" when entering fullscreen.
  PostMessage(window_handle_, kMsgApplyFs, 0, 0);
}

void Win32Window::ExitFullscreen() {
  if (!in_fullscreen_ || !window_handle_) {
    return;
  }
  in_fullscreen_ = false;
  PostMessage(window_handle_, kMsgApplyFs, 0, 0);
}

void Win32Window::ApplyFullscreenEnter() {
  if (!window_handle_) {
    return;
  }
  HMONITOR monitor = MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  GetMonitorInfo(monitor, &mi);
  // Borderless fill of the whole monitor (rcMonitor includes the taskbar area),
  // pinned on top to cover the taskbar.
  SetWindowLongPtr(window_handle_, GWL_STYLE, WS_POPUP);
  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  SetWindowPos(window_handle_, HWND_TOPMOST, mi.rcMonitor.left,
               mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left,
               mi.rcMonitor.bottom - mi.rcMonitor.top, SWP_NOACTIVATE);
}

void Win32Window::ApplyFullscreenExit() {
  if (!window_handle_) {
    return;
  }
  SetWindowLongPtr(window_handle_, GWL_STYLE, saved_fs_style_);
  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  SetWindowPos(window_handle_, HWND_NOTOPMOST, saved_fs_rect_.left,
               saved_fs_rect_.top, saved_fs_rect_.right - saved_fs_rect_.left,
               saved_fs_rect_.bottom - saved_fs_rect_.top, SWP_NOACTIVATE);
}

bool Win32Window::IsFullscreen() const {
  return in_fullscreen_;
}
