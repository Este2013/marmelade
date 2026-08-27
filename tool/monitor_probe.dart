// Bisects the "crashes when dragged to another monitor" fault.
//
//   flutter build windows --debug -t tool/monitor_probe.dart
//   MP_WINDOW_MANAGER=1 build/windows/x64/runner/Debug/marmelade.exe
//
// Each suspect is switched on by an environment variable so one build can test
// many combinations:
//
//   MP_WINDOW_MANAGER  window_manager init + a WindowListener
//   MP_DYNAMIC_COLOR   DynamicColorBuilder around the app
//   MP_SOLOUD          the audio engine, initialised
//   MP_SEMANTICS       a hover-driven AnimatedOpacity, as the album grid has
//   MP_BACKDROP        a BackdropFilter, as the album page has
//   MP_SLIDERS=<n>     n Sliders on screen, as the player bar has
//   MP_SLIDER_SQUASH   squash them into degenerate boxes, as the bar does
//
// The trivial baseline (no variables set) is known to survive the move, so
// whatever combination first dies is the culprit.
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart' as sl;
import 'package:window_manager/window_manager.dart';

bool _on(String name) => Platform.environment[name] == '1';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final enabled = <String>[];

  if (_on('MP_WINDOW_MANAGER')) {
    enabled.add('window_manager');
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1000, 700),
        minimumSize: Size(600, 400),
        center: true,
        title: 'monitor probe',
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    windowManager.addListener(_Listener());
  }

  if (_on('MP_SOLOUD')) {
    enabled.add('soloud');
    try {
      await sl.SoLoud.instance.init(bufferSize: 1024);
    } catch (e) {
      stdout.writeln('soloud failed: $e');
    }
  }

  stdout.writeln('probe enabled: ${enabled.isEmpty ? "(baseline)" : enabled.join(", ")}');
  stdout.writeln('semantics=${_on('MP_SEMANTICS')} backdrop=${_on('MP_BACKDROP')} '
      'dynamicColor=${_on('MP_DYNAMIC_COLOR')}');

  const app = _ProbeApp();
  runApp(_on('MP_DYNAMIC_COLOR')
      ? DynamicColorBuilder(
          builder: (light, dark) => _wrap(app, seed: dark?.primary),
        )
      : _wrap(app));
}

Widget _wrap(Widget child, {Color? seed}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed ?? const Color(0xFFE8730C),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: child,
    );

class _Listener extends WindowListener {
  @override
  void onWindowResize() => stdout.writeln('event: resize');
  @override
  void onWindowMove() => stdout.writeln('event: move');
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (_on('MP_BACKDROP'))
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                child: const ColoredBox(color: Color(0x22FFFFFF)),
              ),
            ),
          Center(
            child: _on('MP_SEMANTICS')
                ? const _HoverGrid()
                : const Text('PROBE', style: TextStyle(fontSize: 32)),
          ),
          if (_sliderCount > 0)
            Align(
              alignment: Alignment.bottomCenter,
              child: _Sliders(count: _sliderCount, squash: _on('MP_SLIDER_SQUASH')),
            ),
        ],
      ),
    );
  }
}

/// Mimics the album grid: hover toggles an AnimatedOpacity over each tile,
/// which is what churns the semantics tree.
int get _sliderCount =>
    int.tryParse(Platform.environment['MP_SLIDERS'] ?? '') ?? 0;

/// N Sliders, optionally squashed the way the real player bar squashes them:
/// the seek bar into a 12px-tall box, the volume slider into a 0-wide one.
class _Sliders extends StatefulWidget {
  const _Sliders({required this.count, required this.squash});
  final int count;
  final bool squash;

  @override
  State<_Sliders> createState() => _SlidersState();
}

class _SlidersState extends State<_Sliders> {
  final _values = <double>[0.3, 0.6, 0.9, 0.2, 0.5];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widget.count; i++)
          SizedBox(
            height: widget.squash && i == 0 ? 12 : null,
            width: widget.squash && i == 1 ? 0 : 200,
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 3,
                padding: EdgeInsets.zero,
              ),
              child: Slider(
                value: _values[i % _values.length],
                onChanged: (v) => setState(() => _values[i % _values.length] = v),
              ),
            ),
          ),
      ],
    );
  }
}

class _HoverGrid extends StatelessWidget {
  const _HoverGrid();

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 4,
      padding: const EdgeInsets.all(24),
      children: [for (var i = 0; i < 24; i++) _HoverTile(index: i)],
    );
  }
}

class _HoverTile extends StatefulWidget {
  const _HoverTile({required this.index});
  final int index;

  @override
  State<_HoverTile> createState() => _HoverTileState();
}

class _HoverTileState extends State<_HoverTile> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedScale(
        scale: _hovering ? 1.03 : 1,
        duration: const Duration(milliseconds: 160),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            Positioned(
              right: 8,
              bottom: 8,
              child: AnimatedOpacity(
                opacity: _hovering ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: IconButton.filled(
                  onPressed: () {},
                  icon: const Icon(Icons.play_arrow),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
