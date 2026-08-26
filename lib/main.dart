import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app/providers.dart';
import 'app/shell.dart';
import 'app/storage_paths.dart';
import 'app/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1320, 860),
      minimumSize: Size(860, 620),
      center: true,
      title: 'marmelade',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  // Storage and the audio engine come up before the first frame, so no screen
  // has to render a loading state for something that is always present.
  // Each step is logged: a stall here shows as a blank window, and without a
  // trace there is nothing to tell "still opening" from "hung".
  debugPrint('marmelade: resolving storage paths');
  final databasePath = await StoragePaths.databaseFile();
  final artworkDirectory = await StoragePaths.artworkDirectory();
  debugPrint('marmelade: database at $databasePath');

  debugPrint('marmelade: starting services');
  final services = await AppServices.start(
    databasePath: databasePath,
    artworkDirectory: artworkDirectory,
  );
  debugPrint('marmelade: services up, running app');

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
}

class MarmeladeApp extends StatelessWidget {
  const MarmeladeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Seeds the palette from the Windows accent colour, falling back to
    // marmelade's own orange when the OS does not report one.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final seed = darkDynamic?.primary ?? lightDynamic?.primary ??
            marmeladeSeed;
        return MaterialApp(
          title: 'marmelade',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: buildTheme(seed: seed, brightness: Brightness.light),
          darkTheme: buildTheme(seed: seed, brightness: Brightness.dark),
          home: const AppShell(),
        );
      },
    );
  }
}

/// Whether the app is running on a platform whose window can be reshaped.
///
/// The mini player and fullscreen modes depend on it.
bool get supportsWindowControls =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;
