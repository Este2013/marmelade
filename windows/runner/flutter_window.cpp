#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Arbitrary, only needing to be unique within this window's own hotkey IDs.
constexpr int kHotkeyPlayPause = 1;
constexpr int kHotkeyNextTrack = 2;
constexpr int kHotkeyPrevTrack = 3;

constexpr char kMediaKeysChannel[] = "marmelade/media_keys";

}  // namespace

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

  media_keys_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kMediaKeysChannel,
          &flutter::StandardMethodCodec::GetInstance());

  // MOD_NOREPEAT so holding the key down doesn't flood WM_HOTKEY. These are
  // dedicated virtual-key codes, not modifier combinations, so no MOD_* flag
  // for the key itself is needed -- just the no-repeat behaviour flag.
  // Global rather than read off WM_APPCOMMAND: a hardware media key should
  // work no matter which window happens to have focus, the same as a
  // physical player's buttons would.
  RegisterHotKey(GetHandle(), kHotkeyPlayPause, MOD_NOREPEAT,
                 VK_MEDIA_PLAY_PAUSE);
  RegisterHotKey(GetHandle(), kHotkeyNextTrack, MOD_NOREPEAT,
                 VK_MEDIA_NEXT_TRACK);
  RegisterHotKey(GetHandle(), kHotkeyPrevTrack, MOD_NOREPEAT,
                 VK_MEDIA_PREV_TRACK);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    UnregisterHotKey(GetHandle(), kHotkeyPlayPause);
    UnregisterHotKey(GetHandle(), kHotkeyNextTrack);
    UnregisterHotKey(GetHandle(), kHotkeyPrevTrack);
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
    case WM_HOTKEY:
      if (media_keys_channel_) {
        switch (wparam) {
          case kHotkeyPlayPause:
            media_keys_channel_->InvokeMethod("playPause", nullptr);
            break;
          case kHotkeyNextTrack:
            media_keys_channel_->InvokeMethod("next", nullptr);
            break;
          case kHotkeyPrevTrack:
            media_keys_channel_->InvokeMethod("previous", nullptr);
            break;
        }
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
