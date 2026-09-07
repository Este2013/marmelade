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
  double contrastLevel = 0,
  DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
  double hueShift = 0,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: hueShift == 0 ? seed : shiftHue(seed, hueShift),
    brightness: brightness,
    // How the palettes are derived from the seed -- whether the seed's own
    // saturation survives, and where tertiary comes from.
    dynamicSchemeVariant: variant,
    // Material's own knob: it moves the tones each role takes out of the
    // palettes, so the colours stay the colours and only the gap between
    // foreground and background changes.
    contrastLevel: contrastLevel,
  );
  return _themeFrom(scheme);
}

/// [color] with its hue turned [degrees] round the wheel.
///
/// A plain rotation, which at 180 is what "the complement" means to anyone
/// looking at a colour wheel. Material has a subtler idea of that --
/// `TemperatureCache.complement`, weighted by warm and cool, which is what
/// the faithful style uses for its tertiary -- but that lives in a package
/// this app only depends on transitively, and the difference does not survive
/// what happens next: the seed contributes its hue and nothing else, since
/// the generator clamps chroma to the variant's own values.
Color shiftHue(Color color, double degrees) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withHue((hsl.hue + degrees) % 360).toColor();
}

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
