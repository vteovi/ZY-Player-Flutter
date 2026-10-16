#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include <cstdio>
#include <fstream>
#include <mutex>
#include <string>

#include "resource.h"

namespace {

/// Appends a diagnostic line to <exe dir>\zy_player_debug.log.
///
/// The native window transitions (real fullscreen / simulated picture-in-picture)
/// can only be exercised by the user's Windows build, so each step is written to
/// a log file next to the executable. If the app becomes unresponsive, the log
/// shows exactly which call was the last one to run.
const std::wstring& DebugLogPath() {
  static const std::wstring path = [] {
    wchar_t module_path[MAX_PATH] = {};
    const DWORD length =
        ::GetModuleFileNameW(nullptr, module_path, MAX_PATH);
    std::wstring result(module_path, length);
    const size_t slash = result.find_last_of(L"\\/");
    if (slash == std::wstring::npos) {
      return std::wstring(L"zy_player_debug.log");
    }
    return result.substr(0, slash + 1) + L"zy_player_debug.log";
  }();
  return path;
}

std::mutex& TraceMutex() {
  static std::mutex mutex;
  return mutex;
}

/// Name of the window messages worth tracing, or nullptr to skip.
const char* MessageName(UINT message) {
  switch (message) {
    case WM_SIZE:
      return "WM_SIZE";
    case WM_NCCALCSIZE:
      return "WM_NCCALCSIZE";
    case WM_WINDOWPOSCHANGING:
      return "WM_WINDOWPOSCHANGING";
    case WM_WINDOWPOSCHANGED:
      return "WM_WINDOWPOSCHANGED";
    case WM_NCACTIVATE:
      return "WM_NCACTIVATE";
    case WM_SHOWWINDOW:
      return "WM_SHOWWINDOW";
    case WM_STYLECHANGING:
      return "WM_STYLECHANGING";
    case WM_STYLECHANGED:
      return "WM_STYLECHANGED";
    case WM_ACTIVATE:
      return "WM_ACTIVATE";
    case WM_DPICHANGED:
      return "WM_DPICHANGED";
    case WM_CLOSE:
      return "WM_CLOSE";
    default:
      return nullptr;
  }
}

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
  TraceReset();
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
  if (const char* name = MessageName(message)) {
    char buffer[96];
    sprintf_s(buffer, sizeof(buffer), "msg %s wparam=%llu", name,
              static_cast<unsigned long long>(wparam));
    Trace(buffer);
  }
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

    case WM_GETMINMAXINFO:
      // Resizing the small floating window: never let the user shrink it below
      // a sensible minimum (200x120 logical px, scaled by the monitor DPI), so
      // it can not be squeezed into an unusable strip.
      if (in_pip_) {
        auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
        HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
        info->ptMinTrackSize.x = static_cast<LONG>(200 * scale);
        info->ptMinTrackSize.y = static_cast<LONG>(120 * scale);
        return 0;
      }
      break;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;

    case kMsgApplyPip:
      Trace("  apply-pip message");
      if (pending_pip_ == PipAction::kEnter) {
        ApplyPipEnter(pending_pip_aspect_);
      } else if (pending_pip_ == PipAction::kExit) {
        ApplyPipExit();
      }
      pending_pip_ = PipAction::kNone;
      return 0;

    case kMsgApplyFs:
      Trace("  apply-fullscreen message");
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

void Win32Window::Trace(const char* text) {
  std::lock_guard<std::mutex> lock(TraceMutex());
  std::ofstream out(DebugLogPath().c_str(), std::ios::app);
  if (!out) {
    return;
  }
  SYSTEMTIME now{};
  ::GetLocalTime(&now);
  char stamp[32];
  sprintf_s(stamp, sizeof(stamp), "%02u:%02u:%02u.%03u",
            static_cast<unsigned>(now.wHour),
            static_cast<unsigned>(now.wMinute),
            static_cast<unsigned>(now.wSecond),
            static_cast<unsigned>(now.wMilliseconds));
  out << stamp << "  " << text << "\n";
}

void Win32Window::TraceReset() {
  std::lock_guard<std::mutex> lock(TraceMutex());
  std::ofstream out(DebugLogPath().c_str(), std::ios::trunc);
  out << "=== zy_player native window trace ===\n";
}

void Win32Window::EnterPip(double aspect) {
  if (in_pip_ || !window_handle_) {
    return;
  }
  // Capture the normal geometry only when coming from the normal state (not
  // from fullscreen), so exiting PiP always returns to the true normal window.
  if (!in_fullscreen_) {
    normal_style_ =
        static_cast<DWORD>(GetWindowLongPtr(window_handle_, GWL_STYLE));
    GetWindowRect(window_handle_, &normal_rect_);
  }
  in_fullscreen_ = false;  // PiP and fullscreen are mutually exclusive.
  in_pip_ = true;
  pending_pip_aspect_ = aspect;
  pending_pip_ = PipAction::kEnter;
  Trace("EnterPip: posted apply");
  // Defer the real style/size change to the message loop: doing it inside the
  // Flutter method-channel callback re-enters the engine's window handling.
  PostMessage(window_handle_, kMsgApplyPip, 0, 0);
}

void Win32Window::ExitPip() {
  if (!in_pip_ || !window_handle_) {
    return;
  }
  in_pip_ = false;
  // Mark the pending action so the deferred handler actually restores the
  // window (without this the handler sees kNone and does nothing, so PiP can
  // never be exited).
  pending_pip_ = PipAction::kExit;
  Trace("ExitPip: posted apply");
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
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  GetMonitorInfo(monitor, &mi);
  int x = mi.rcWork.right - w - 24;
  int y = mi.rcWork.bottom - h - 24;

  // Modify the current style in place (instead of assigning a brand new style)
  // so every other bit such as WS_VISIBLE / WS_CLIPCHILDREN survives.
  //
  // No caption / system menu / minimise / maximise: a WS_CAPTION title bar is
  // painted by the system in the light theme, which showed up as a stray white
  // bar above the video. WS_THICKFRAME is kept only because the system's modal
  // resize loop (StartPipResize) and its minimum tracking size expect a sizing
  // border - the border itself is never drawn, because WM_NCCALCSIZE gives the
  // window a zero-sized non-client area (see FlutterWindow::MessageHandler), so
  // the whole window is video. Moving/resizing are handed over to the system
  // loops and closing to the Flutter overlay button.
  LONG_PTR style = GetWindowLongPtr(window_handle_, GWL_STYLE);
  style &= ~(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX |
             WS_BORDER | WS_DLGFRAME);
  style |= WS_POPUP | WS_THICKFRAME | WS_CLIPCHILDREN | WS_VISIBLE;
  Trace("ApplyPipEnter: set style");
  SetWindowLongPtr(window_handle_, GWL_STYLE, style);
  // A single SetWindowPos that applies style + position + size at once (the
  // same shape of call used by the well tested window_manager plugin).
  Trace("ApplyPipEnter: set window pos");
  SetWindowPos(window_handle_, HWND_TOPMOST, x, y, w, h,
               SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
  Trace("ApplyPipEnter: done");
}

void Win32Window::ApplyPipExit() {
  if (!window_handle_) {
    return;
  }
  Trace("ApplyPipExit: restore style");
  SetWindowLongPtr(window_handle_, GWL_STYLE, normal_style_);
  Trace("ApplyPipExit: restore window pos");
  SetWindowPos(window_handle_, HWND_NOTOPMOST, normal_rect_.left,
               normal_rect_.top, normal_rect_.right - normal_rect_.left,
               normal_rect_.bottom - normal_rect_.top,
               SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
  Trace("ApplyPipExit: done");
}

bool Win32Window::IsInPip() const {
  return in_pip_;
}

void Win32Window::StartPipDrag() {
  if (!in_pip_ || !window_handle_) {
    return;
  }
  // A borderless window has no caption, so Windows has nothing to grab for
  // dragging, and mouse input goes to the Flutter child view instead of the
  // top-level window (a WM_NCHITTEST override on the top-level never sees it).
  // The reliable way is to hand the move over to the system's modal move loop:
  // ReleaseCapture() + WM_NCLBUTTONDOWN with HTCAPTION. This is exactly what
  // the well tested window_manager plugin does for its startDragging().
  //
  // lParam carries the current cursor position (non-client messages use screen
  // coordinates): the loop derives the grab offset from it, so passing the real
  // position keeps the window under the cursor instead of jumping.
  //
  // It blocks inside the move loop until the user releases the button, which is
  // expected: the loop keeps pumping messages, so the app keeps rendering. Only
  // the window position changes (never its size), so the video texture is never
  // re-created here.
  POINT cursor{};
  GetCursorPos(&cursor);
  Trace("StartPipDrag: entering system move loop");
  ReleaseCapture();
  SendMessage(window_handle_, WM_NCLBUTTONDOWN, HTCAPTION,
              MAKELPARAM(cursor.x, cursor.y));
  Trace("StartPipDrag: move loop finished");
}

void Win32Window::StartPipResize(int ht) {
  if (!in_pip_ || !window_handle_) {
    return;
  }
  if (ht < HTLEFT || ht > HTBOTTOMRIGHT) {
    return;
  }
  // Same hand-over as StartPipDrag, but with a border hit-test code: the system
  // runs its own resize loop, so the drag is tracked natively (works even when
  // the cursor leaves the small window). The window keeps WS_THICKFRAME for
  // this to be accepted, while WM_NCCALCSIZE returns a zero-sized non-client
  // area so no frame is ever painted (see FlutterWindow::MessageHandler).
  //
  // Flutter detaches the video texture before calling this - changing the window
  // *size* while fvp is streaming into the D3D11 shared texture is what used to
  // freeze the whole app.
  POINT cursor{};
  GetCursorPos(&cursor);
  Trace("StartPipResize: entering system resize loop");
  ReleaseCapture();
  SendMessage(window_handle_, WM_NCLBUTTONDOWN, static_cast<WPARAM>(ht),
              MAKELPARAM(cursor.x, cursor.y));
  Trace("StartPipResize: resize loop finished");
}

void Win32Window::EnterFullscreen() {
  if (in_fullscreen_ || !window_handle_) {
    return;
  }
  // Capture the normal geometry only when coming from the normal state (not
  // from PiP), so exiting fullscreen always returns to the true normal window.
  if (!in_pip_) {
    normal_style_ =
        static_cast<DWORD>(GetWindowLongPtr(window_handle_, GWL_STYLE));
    GetWindowRect(window_handle_, &normal_rect_);
  }
  in_pip_ = false;  // PiP and fullscreen are mutually exclusive.
  in_fullscreen_ = true;
  pending_fs_ = FsAction::kEnter;
  Trace("EnterFullscreen: posted apply");
  PostMessage(window_handle_, kMsgApplyFs, 0, 0);
}

void Win32Window::ExitFullscreen() {
  if (!in_fullscreen_ || !window_handle_) {
    return;
  }
  in_fullscreen_ = false;
  // Mark the pending action so the deferred handler actually restores the
  // window (without this the handler sees kNone and does nothing).
  pending_fs_ = FsAction::kExit;
  Trace("ExitFullscreen: posted apply");
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
  // pinned on top to cover the taskbar. Style bits are modified in place so that
  // WS_VISIBLE etc. survive (see ApplyPipEnter).
  LONG_PTR style = GetWindowLongPtr(window_handle_, GWL_STYLE);
  style &= ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
  style |= WS_POPUP | WS_CLIPCHILDREN | WS_VISIBLE;
  Trace("ApplyFullscreenEnter: set style");
  SetWindowLongPtr(window_handle_, GWL_STYLE, style);
  Trace("ApplyFullscreenEnter: set window pos");
  SetWindowPos(window_handle_, HWND_TOPMOST, mi.rcMonitor.left,
               mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left,
               mi.rcMonitor.bottom - mi.rcMonitor.top,
               SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
  Trace("ApplyFullscreenEnter: done");
}

void Win32Window::ApplyFullscreenExit() {
  if (!window_handle_) {
    return;
  }
  Trace("ApplyFullscreenExit: restore style");
  SetWindowLongPtr(window_handle_, GWL_STYLE, normal_style_);
  Trace("ApplyFullscreenExit: restore window pos");
  SetWindowPos(window_handle_, HWND_NOTOPMOST, normal_rect_.left,
               normal_rect_.top, normal_rect_.right - normal_rect_.left,
               normal_rect_.bottom - normal_rect_.top,
               SWP_NOOWNERZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE);
  Trace("ApplyFullscreenExit: done");
}

bool Win32Window::IsFullscreen() const {
  return in_fullscreen_;
}
