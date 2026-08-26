import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 820),
      minimumSize: Size(720, 560),
      center: true,
      title: 'marmelade',
      titleBarStyle: TitleBarStyle.normal,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(const ProviderScope(child: MarmeladeApp()));
}

class MarmeladeApp extends StatelessWidget {
  const MarmeladeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Seeds the palette from the Windows accent colour, falling back to
    // marmelade's own orange when the OS does not report one.
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final seed = lightDynamic?.primary ?? marmeladeSeed;
        return MaterialApp(
          title: 'marmelade',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: buildTheme(seed: seed, brightness: Brightness.light),
          darkTheme: buildTheme(seed: seed, brightness: Brightness.dark),
          home: const _Placeholder(),
        );
      },
    );
  }
}

/// Temporary landing screen. Replaced by the library shell.
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('marmelade',
                style: Theme.of(context).textTheme.displayMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w300,
                    )),
            const SizedBox(height: 8),
            Text('we be jamming to the tunes',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    )),
          ],
        ),
      ),
    );
  }
}
