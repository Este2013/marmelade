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
/// [content] is the merged toolbar: a view's own title, filters and sort
/// controls, or a detail page's back/edit row, or the now-playing shade's
/// close button and label -- whatever the current screen would otherwise have
/// drawn as a separate bar directly underneath. There used to be one; the
/// space it took is exactly the drag area this strip has always had, so
/// merging the two loses nothing draggable: the drag area moves *behind*
/// [content] instead of sitting empty beside it. A real control (a button, a
/// text field) is painted on top and wins the hit test where it sits; anywhere
/// else in the strip -- the gap between a title and its controls, the margin
/// around a chip -- falls through to the drag area behind it. No view has to
/// reserve or calculate its own draggable gap for this to work.
///
/// Drawn as the topmost layer, so it stays above the now-playing shade too: a
/// window you cannot move or close because a panel is open would be a poor
/// trade for the extra immersion.
class WindowChrome extends StatelessWidget {
  const WindowChrome({
    super.key,
    this.content,
    this.trailing,
    this.contentInset = 0,
  });

  /// Height of the strip, in logical pixels.
  ///
  /// Tall enough for a full toolbar row -- title, count, a filter field, a
  /// sort dropdown -- on one line; the same height everywhere, now-playing
  /// included, rather than one height for a slim strip and another for a busy
  /// one.
  static const height = 56.0;

  /// The current screen's own toolbar, filling the strip apart from
  /// [trailing] and the window buttons.
  ///
  /// Null when a screen has nothing to put here (there always is one in
  /// practice, but nothing requires it). Kept as an opaque widget so this file
  /// stays about the window and knows nothing about any particular view.
  final Widget? content;

  /// Controls placed after [content], before the window buttons.
  ///
  /// A second slot rather than folding everything into [content] because a
  /// couple of screens (the now-playing shade) want a small fixed-width group
  /// pinned next to the window buttons regardless of how [content] lays
  /// itself out.
  final Widget? trailing;

  /// Space reserved before [content] starts.
  ///
  /// The strip runs the full width, over the rail's top as well -- see the
  /// drag layer below -- but [content] itself must not: unlike the drag area,
  /// it actually paints something, and painted content starting at the
  /// window's left edge lands on top of whatever the rail draws there (its
  /// logo, a destination). The caller measures the rail and passes its width
  /// here; zero on the one screen where that no longer applies, the
  /// now-playing shade, because the shade's own backdrop already covers the
  /// rail by the time its controls would need to clear it.
  final double contentInset;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          // Full width, underneath everything else: see the class comment for
          // why this is a background layer rather than a slice of the Row.
          const Positioned.fill(child: _DragStrip()),
          Row(
            children: [
              // The strip runs the full width, over the rail's top as well. The
              // rail's first destination starts below it, so nothing
              // interactive is covered, and in exchange the entire top edge of
              // the window drags -- which is what the edge of a window is
              // expected to do.
              SizedBox(width: contentInset),
              // Always an Expanded, even with nothing to show, so this claims
              // the flex space that keeps trailing and the window buttons
              // pinned to the right edge instead of collapsing left.
              Expanded(
                child: content == null
                    ? const SizedBox.shrink()
                    // One place for the margin every screen's toolbar used to
                    // set for itself, so moving a toolbar here does not also
                    // mean copying its padding.
                    : Padding(
                        padding: const EdgeInsets.only(left: 24, right: 8),
                        child: content!,
                      ),
              ),
              ?trailing,
              const _WindowButtons(),
            ],
          ),
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
