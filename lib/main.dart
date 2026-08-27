import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app/providers.dart';
import 'app/shell.dart';
import 'app/storage_paths.dart';
import 'app/theme/app_theme.dart';
import 'core/debug/screenshotter.dart';
import 'core/logging/app_log.dart';

/// How much decoded image data to keep.
///
/// Set explicitly rather than left at Flutter's 100 MB default, because album
/// art is the dominant allocation in this app and the default is small enough
/// that a grid of covers evicts and re-decodes continuously.
const _imageCacheBytes = 220 * 1024 * 1024;
const _imageCacheCount = 400;

/// Opening window size, in logical pixels.
///
/// Wide enough for the now-playing view's two-pane layout and a six-column
/// album grid.
const _windowSize = Size(1320, 860);

/// The smallest the window may be dragged, in logical pixels.
///
/// The layouts are built and tested down to this and no further.
const _minimumWindowSize = Size(860, 620);

Future<void> main() async {
  // Everything runs inside one zone, bindings included. Initialising the
  // bindings outside the guasrded zone and calling runApp inside it makes
  // Flutter complain about a zone mismatch, and it is right to: zone-specific
  // configuration would then be applied inconsistently.
  await runGuardedWithLogging(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Logging comes up before anything that can fail, so a crash during
    // startup still leaves a trace on disk.
    final logDirectory = await StoragePaths.logsDirectory();
    final log = await AppLog.initialize(directory: logDirectory);
    installErrorHandlers();

    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.maximumSizeBytes = _imageCacheBytes;
    imageCache.maximumSize = _imageCacheCount;
    log.info('image cache configured', fields: {'bytes': AppLog.formatBytes(_imageCacheBytes), 'entries': _imageCacheCount});

    log.info('initialising window');
    await windowManager.ensureInitialized();

    // window_manager 0.5.2 takes these sizes in *physical* pixels on Windows,
    // not logical ones, so they have to be scaled by hand. On a 175% display
    // the unscaled numbers open the window at 754 logical pixels wide - below
    // the app's own stated minimum, and narrow enough to fold the now-playing
    // view into its single-pane layout on a large monitor. The minimum needs
    // the same treatment, or the window can be dragged down to 491x354
    // logical, far below anything the layout is built or tested for.
    final scale = PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;
    log.info('window scale', fields: {'devicePixelRatio': scale, 'logical': '${_windowSize.width}x${_windowSize.height}', 'physical': '${(_windowSize.width * scale).round()}x${(_windowSize.height * scale).round()}'});

    await windowManager.waitUntilReadyToShow(WindowOptions(size: _windowSize * scale, minimumSize: _minimumWindowSize * scale, center: true, title: 'marmelade', titleBarStyle: TitleBarStyle.normal), () async {
      await windowManager.show();
      await windowManager.focus();
    });

    log.info('resolving storage paths');
    final databasePath = await StoragePaths.databaseFile();
    final artworkDirectory = await StoragePaths.artworkDirectory();
    log.info('storage resolved', fields: {'database': databasePath, 'artwork': artworkDirectory.path});

    // Storage and the audio engine come up before the first frame, so no
    // screen has to render a loading state for something that is always
    // present. A stall here shows as a blank window, so each step is logged.
    final services = await AppServices.start(databasePath: databasePath, artworkDirectory: artworkDirectory);
    log.info('services up', fields: {'rss': AppLog.formatBytes(AppLog.residentBytes())});

    // A window close is the normal way this app exits; without a marker there
    // is no way to tell a clean shutdown from a crash in the log.
    windowManager.addListener(_ShutdownLogger(services));

    log.info('running app');
    runApp(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(services.db),
          artStoreProvider.overrideWithValue(services.artStore),
          playbackEngineProvider.overrideWithValue(services.engine),
          playerProvider.overrideWith(services.createPlayer),
        ],
        child: const MarmeladeApp(),
      ),
    );
  });
}

/// Writes the session-end marker when the window closes.
class _ShutdownLogger extends WindowListener {
  _ShutdownLogger(this.services);

  final AppServices services;

  @override
  void onWindowClose() {
    AppLog.instance.sessionEnd('window closed');
  }
}

class MarmeladeApp extends StatelessWidget {
  const MarmeladeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Seeds the palette from the Windows accent colour, falling back to
    // marmelade's own orange when the OS does not report one.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final seed = darkDynamic?.primary ?? lightDynamic?.primary ?? marmeladeSeed;
        return MaterialApp(
          title: 'marmelade',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: buildTheme(seed: seed, brightness: Brightness.light),
          darkTheme: buildTheme(seed: seed, brightness: Brightness.dark),
          // Diagnostic: MARMELADE_NO_SEMANTICS=1 strips the accessibility
          // tree, to test whether a fault is the accessibility bridge's.
          home: Screenshotter.boundary(
            child: Platform.environment['MARMELADE_NO_SEMANTICS'] == '1'
                ? const ExcludeSemantics(child: AppShell())
                : const AppShell(),
          ),
        );
      },
    );
  }
}

/// Whether the app is running on a platform whose window can be reshaped.
///
/// The mini player and fullscreen modes depend on it.
bool get supportsWindowControls => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
