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
  bool swapAccents = false,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
    // How the palettes are derived from the seed -- whether the seed's own
    // saturation survives, and where tertiary comes from.
    dynamicSchemeVariant: variant,
    // Material's own knob: it moves the tones each role takes out of the
    // palettes, so the colours stay the colours and only the gap between
    // foreground and background changes.
    contrastLevel: contrastLevel,
  );
  return _themeFrom(swapAccents ? swapPrimaryAndTertiary(scheme) : scheme);
}

/// Trades the primary and tertiary roles, group for group.
///
/// There is no Material variant for this, so it happens after the scheme is
/// built. Every member of each group moves together -- the containers and the
/// fixed roles as well as the accent itself -- because a scheme with a
/// swapped `primary` and an unswapped `onPrimary` is one where text sits on
/// the wrong colour.
///
/// `inversePrimary` stays put: there is no tertiary counterpart to trade it
/// with, and it is only used on inverse surfaces.
ColorScheme swapPrimaryAndTertiary(ColorScheme s) => s.copyWith(
      primary: s.tertiary,
      onPrimary: s.onTertiary,
      primaryContainer: s.tertiaryContainer,
      onPrimaryContainer: s.onTertiaryContainer,
      primaryFixed: s.tertiaryFixed,
      primaryFixedDim: s.tertiaryFixedDim,
      onPrimaryFixed: s.onTertiaryFixed,
      onPrimaryFixedVariant: s.onTertiaryFixedVariant,
      tertiary: s.primary,
      onTertiary: s.onPrimary,
      tertiaryContainer: s.primaryContainer,
      onTertiaryContainer: s.onPrimaryContainer,
      tertiaryFixed: s.primaryFixed,
      tertiaryFixedDim: s.primaryFixedDim,
      onTertiaryFixed: s.onPrimaryFixed,
      onTertiaryFixedVariant: s.onPrimaryFixedVariant,
    );

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
