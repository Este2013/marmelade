import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// The app's own title bar, replacing the one Windows draws.
///
/// The native caption is hidden so the navigation rail can run to the top edge
/// of the window and the controls can sit on the app's own colours. The window
/// frame itself is untouched -- border, shadow and resize edges are all still
/// Windows' -- so this is only the caption strip, not a reimplementation of the
/// window.
///
/// Drawn as the topmost layer and transparent, so whatever is beneath shows
/// through and the strip is never a differently-coloured band. It stays above
/// the now-playing shade too: a window you cannot move or close because a panel
/// is open would be a poor trade for the extra immersion.
class WindowChrome extends StatelessWidget {
  const WindowChrome({super.key, this.leading, this.trailing});

  /// Height of the strip, in logical pixels.
  ///
  /// Matches Windows' own caption height closely enough that the controls land
  /// where the muscle memory expects them.
  static const height = 40.0;

  /// Controls placed at the left end of the strip, before the drag area.
  ///
  /// The strip is the only chrome the window has, so anything that belongs to
  /// the window as a whole rather than to a view belongs here. Kept as opaque
  /// widgets so this file stays about the window and knows nothing about the
  /// player.
  final Widget? leading;

  /// Controls placed after the drag area, before the window buttons.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          ?leading,
          // The strip runs the full width, over the rail's top as well. The
          // rail's first destination starts below it, so nothing interactive is
          // covered, and in exchange the entire top edge of the window drags --
          // which is what the edge of a window is expected to do. Reserving a
          // gap for the rail would mean hard-coding its width, and a rail with
          // labels is wider than its minWidth suggests.
          const Expanded(child: _DragStrip()),
          ?trailing,
          const _WindowButtons(),
        ],
      ),
    );
  }
}

/// The draggable part of the strip.
class _DragStrip extends StatelessWidget {
  const _DragStrip();

  @override
  Widget build(BuildContext context) {
    // DragToMoveArea also handles double-click to maximise, which is the one
    // caption behaviour people notice missing.
    return const DragToMoveArea(child: SizedBox.expand());
  }
}

/// Minimise, maximise and close.
class _WindowButtons extends StatefulWidget {
  const _WindowButtons();

  @override
  State<_WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<_WindowButtons> with WindowListener {
  var _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // The window may already be maximised when this mounts, and no event is
    // sent for state that was set before anyone was listening. Failure is
    // survivable and must not become an unhandled async error: under a widget
    // test there is no platform channel to answer, and the caption is not
    // worth failing a test over.
    windowManager.isMaximized().then(
      (value) {
        if (mounted && value != _maximized) setState(() => _maximized = value);
      },
      onError: (Object _) {},
    );
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    // WindowCaptionButton paints Windows' own hover and pressed treatments,
    // including the red close button, which is worth keeping: these three are
    // the controls people expect to behave exactly as they always have.
    final brightness = Theme.of(context).brightness;

    return Row(
      children: [
        WindowCaptionButton.minimize(
          brightness: brightness,
          onPressed: windowManager.minimize,
        ),
        if (_maximized)
          WindowCaptionButton.unmaximize(
            brightness: brightness,
            onPressed: windowManager.unmaximize,
          )
        else
          WindowCaptionButton.maximize(
            brightness: brightness,
            onPressed: windowManager.maximize,
          ),
        WindowCaptionButton.close(
          brightness: brightness,
          onPressed: windowManager.close,
        ),
      ],
    );
  }
}
