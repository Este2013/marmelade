import 'package:flutter/material.dart';

/// marmelade's colour identity. Used when the OS accent colour is unavailable
/// and as the "brand" option in settings.
const marmeladeSeed = Color(0xFFE8730C); // marmalade orange

/// Builds the app theme from a seed colour.
///
/// [seed] is normally the Windows accent colour (see `systemAccentProvider`),
/// falling back to [marmeladeSeed].
ThemeData buildTheme({
  required Color seed,
  required Brightness brightness,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );
  return _themeFrom(scheme);
}

/// Builds a theme from an already-derived scheme, e.g. one generated from
/// album art by [ColorScheme.fromImageProvider].
ThemeData themeFromScheme(ColorScheme scheme) => _themeFrom(scheme);

ThemeData _themeFrom(ColorScheme scheme) {
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    // Desktop app: tighter density than the phone default.
    visualDensity: VisualDensity.compact,
    splashFactory: InkSparkle.splashFactory,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.windows: FadeForwardsPageTransitionsBuilder()},
    ),
  );
}
