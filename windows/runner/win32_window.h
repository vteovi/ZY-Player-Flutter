#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

  // Desktop simulated picture-in-picture: turns the main window into a
  // top-most, borderless, draggable/resizable floating window. Since fvp
  // renders into a Flutter Texture, shrinking the window shrinks the video,
  // so it floats above other windows. |aspect| is the video aspect ratio
  // (width / height) used to compute the small window size. The current window
  // style and position/size are saved before entering and restored on exit.
  void EnterPip(double aspect);
  void ExitPip();
  bool IsInPip() const;

  // Desktop real window fullscreen: turns the main window borderless and fills
  // the whole monitor (including the taskbar area), pinned on top. If currently
  // in simulated PiP, it exits the floating window first; the two are mutually
  // exclusive.
  void EnterFullscreen();
  void ExitFullscreen();
  bool IsFullscreen() const;

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  // Apply the pending PiP / fullscreen window change on the message loop
  // (posted from Enter*/Exit*). Performing the style/size change synchronously
  // inside the Flutter method-channel handler re-enters the engine's WM_SIZE
  // handling and deadlocks the UI thread (the window "freezes"); deferring the
  // work onto the message loop avoids that.
  void ApplyPipEnter(double aspect);
  void ApplyPipExit();
  void ApplyFullscreenEnter();
  void ApplyFullscreenExit();

  static constexpr UINT kMsgApplyPip = WM_APP + 1;
  static constexpr UINT kMsgApplyFs = WM_APP + 2;

  enum class PipAction { kNone, kEnter, kExit };
  enum class FsAction { kNone, kEnter, kExit };

  PipAction pending_pip_ = PipAction::kNone;
  double pending_pip_aspect_ = 16.0 / 9.0;
  FsAction pending_fs_ = FsAction::kNone;

  bool quit_on_close_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;

  // Current special display mode. PiP and fullscreen are mutually exclusive.
  bool in_pip_ = false;
  bool in_fullscreen_ = false;

  // Normal (non-PiP, non-fullscreen) window style and position/size, captured
  // when entering any special mode from the normal state and restored on exit.
  // A single pair suffices because the special modes are mutually exclusive,
  // and it guarantees exits always return to the true normal geometry even if
  // the special modes are switched directly from one to the other.
  DWORD normal_style_ = 0;
  RECT normal_rect_ = {0, 0, 0, 0};
};

#endif  // RUNNER_WIN32_WINDOW_H_
