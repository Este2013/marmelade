import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../logging/app_log.dart';

/// Captures the running app's own pixels to a PNG.
///
/// Windows renders Flutter through ANGLE onto a DirectComposition surface,
/// which every ordinary screen-capture route -- GDI `BitBlt`, `PrintWindow`
/// with `PW_RENDERFULLCONTENT`, ffmpeg's `ddagrab` -- reads back as a blank
/// rectangle. That leaves no way to look at the real window with the real
/// library in it, which is precisely the thing worth looking at.
///
/// So the app photographs itself: Flutter's own rasteriser already holds the
/// composited scene, and [RenderRepaintBoundary.toImage] hands it over. This
/// is a debug affordance, driven entirely by environment variables so it costs
/// a single `if` in a normal run:
///
/// ```
/// MARMELADE_SHOT=C:\tmp\albums.png MARMELADE_SHOT_DELAY_MS=9000 marmelade.exe
/// ```
///
/// With `MARMELADE_SHOT_EXIT=1` the app writes the file and quits, which makes
/// it scriptable.
abstract final class Screenshotter {
  /// Wrapped around the app so there is something to capture.
  static final rootKey = GlobalKey();

  static String? get _target => Platform.environment['MARMELADE_SHOT'];

  /// Whether a capture was requested at all.
  static bool get isRequested => (_target ?? '').isNotEmpty;

  /// How long to wait before capturing.
  ///
  /// Artwork decodes asynchronously, so an immediate capture would show a grid
  /// of empty placeholders and prove nothing.
  static Duration get _delay => Duration(
        milliseconds:
            int.tryParse(Platform.environment['MARMELADE_SHOT_DELAY_MS'] ?? '') ??
                9000,
      );

  static double get _pixelRatio =>
      double.tryParse(Platform.environment['MARMELADE_SHOT_SCALE'] ?? '') ?? 1.0;

  static bool get _exitAfter =>
      Platform.environment['MARMELADE_SHOT_EXIT'] == '1';

  /// Wraps [child] so its pixels can be read back.
  static Widget boundary({required Widget child}) =>
      RepaintBoundary(key: rootKey, child: child);

  /// Schedules the capture, if one was asked for.
  static void scheduleIfRequested() {
    if (!isRequested) return;
    final path = _target!;
    final log = AppLog.instance;
    log.warn('screenshot requested', fields: {
      'path': path,
      'delay': '${_delay.inMilliseconds}ms',
    });

    Future<void>.delayed(_delay, () async {
      try {
        await capture(path);
        log.info('screenshot written', fields: {'path': path});
      } catch (error, stack) {
        log.error('screenshot failed', error: error, stack: stack);
      }
      if (_exitAfter) {
        log.sessionEnd('screenshot finished');
        exit(0);
      }
    });
  }

  /// Writes the current frame to [path] as a PNG.
  static Future<void> capture(String path) async {
    final context = rootKey.currentContext;
    if (context == null) {
      throw StateError('no boundary in the tree yet');
    }
    final boundary = context.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      throw StateError('boundary has no render object');
    }
    // A boundary that still needs paint would hand back the previous frame, or
    // nothing at all on the very first one.
    if (boundary.debugNeedsPaint) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    final image = await boundary.toImage(pixelRatio: _pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('encoding to PNG returned nothing');
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    } finally {
      image.dispose();
    }
  }
}
