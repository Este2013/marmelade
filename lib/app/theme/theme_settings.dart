import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Where the palette's seed colour comes from.
enum AccentSource {
  /// The Windows accent colour, so the app matches the desktop it sits on.
  system('Windows accent'),

  /// Drawn from the artwork of whatever is playing, everywhere at once.
  ///
  /// There used to be a separate switch for tinting the player. It was
  /// redundant: seeding the app from the artwork produces the same scheme the
  /// player was deriving for itself -- measured identical to within a hex
  /// digit -- so two controls could only ever agree loudly or disagree
  /// quietly.
  adaptive('Adaptive'),

  /// A colour chosen here.
  custom('A colour I picked');

  const AccentSource(this.label);

  final String label;

  static AccentSource of(String name) =>
      AccentSource.values.where((s) => s.name == name).firstOrNull ??
      AccentSource.system;
}

/// How far apart the palette's foreground and background tones sit.
///
/// Material's own parameter, not something computed here: `contrastLevel`
/// moves the tones each role takes out of its palette, so higher settings
/// guarantee a wider gap between pairs like primary and onPrimary. Off the
/// same seed, so the colours stay the colours -- this is legibility, not a
/// different palette.
enum ContrastLevel {
  /// Softer than the default, for a dim room.
  ///
  /// -0.5 rather than the -1.0 the parameter allows: measured against the
  /// brand seed, -1.0 puts secondary text on surface at 4.07:1 in the light
  /// theme, under the 4.5:1 that body text is meant to clear. -0.5 measures
  /// 5.07 there and 6.08 in dark.
  muted('Muted', -0.5),

  /// Material's normal contrast, and what every build so far has used.
  normal('Default', 0),

  /// What Material calls medium contrast.
  high('High', 0.5),

  /// Material's high contrast: near-black on near-white, or the reverse.
  highest('Highest', 1);

  const ContrastLevel(this.label, this.value);

  final String label;

  /// Passed straight to `ColorScheme.fromSeed`.
  final double value;

  static ContrastLevel of(String name) =>
      ContrastLevel.values.where((c) => c.name == name).firstOrNull ??
      ContrastLevel.normal;
}

/// How the palette is derived from the seed.
///
/// Material's `DynamicSchemeVariant`, exposed because the differences are
/// large and entirely a matter of taste -- and because the default clamps
/// chroma to fixed values, which means a muted cover and a vivid one at the
/// same hue currently produce the same palette. `fidelity` and `content` are
/// the two that keep the seed's own saturation.
enum PaletteVariant {
  /// Material's default: pastel palettes at fixed chroma, tertiary rotated
  /// 60 degrees off the seed's hue.
  tonalSpot('Material default', DynamicSchemeVariant.tonalSpot),

  /// Keeps the seed's own chroma, and makes tertiary its complement. The one
  /// to try if a washed-out sleeve should give a washed-out theme.
  fidelity('Faithful', DynamicSchemeVariant.fidelity),

  /// Primary chroma at maximum. Loud.
  vibrant('Vibrant', DynamicSchemeVariant.vibrant),

  /// Medium chroma, and the primary hue deliberately shifted off the seed.
  expressive('Expressive', DynamicSchemeVariant.expressive),

  /// A hint of chroma, close to grey.
  neutral('Neutral', DynamicSchemeVariant.neutral),

  /// No chroma at all.
  monochrome('Monochrome', DynamicSchemeVariant.monochrome),

  /// Playful: the seed's hue does not appear in the theme at all.
  rainbow('Rainbow', DynamicSchemeVariant.rainbow),

  /// The other playful one, same idea.
  fruitSalad('Fruit salad', DynamicSchemeVariant.fruitSalad),

  /// The whole palette built from the accent's opposite.
  ///
  /// Not a Material variant -- there is no such thing -- but the seed turned
  /// half a circle before the palettes are derived from it. Trading the
  /// primary and tertiary *roles* was the first attempt at this and reads as
  /// far less of a change than it sounds, because under the default tertiary
  /// is only 60 degrees off the seed. A complement is the whole way round.
  swapped('Swapped', DynamicSchemeVariant.tonalSpot, hueShift: 180);

  const PaletteVariant(this.label, this.variant, {this.hueShift = 0});

  final String label;

  /// Passed straight to `ColorScheme.fromSeed`.
  final DynamicSchemeVariant variant;

  /// Degrees the seed's hue turns before any palette is built from it.
  ///
  /// A number rather than a flag because the blurred artwork behind the
  /// now-playing view turns by the same amount: a palette that crossed the
  /// colour wheel while the picture behind it stayed put is two moods at
  /// once. Zero for every style whose shifting happens inside Material's own
  /// generator, where there is no single angle to follow.
  final double hueShift;

  static PaletteVariant of(String name) =>
      PaletteVariant.values.where((v) => v.name == name).firstOrNull ??
      PaletteVariant.tonalSpot;
}

/// Everything the appearance settings decide.
///
/// A value type rather than three loose providers: the theme is built from all
/// of it at once, and three separate rebuild paths for one visual result is how
/// a UI ends up flickering through intermediate palettes on startup.
class ThemePreference {
  const ThemePreference({
    this.mode = ThemeMode.dark,
    this.accent = AccentSource.system,
    this.customAccent = marmeladeSeed,
    this.contrast = ContrastLevel.normal,
    this.variant = PaletteVariant.tonalSpot,
  });

  final ThemeMode mode;
  final AccentSource accent;
  final Color customAccent;
  final ContrastLevel contrast;
  final PaletteVariant variant;

  /// The seed to build the palette from.
  ///
  /// [systemAccent] is what the OS reported, which is null often enough --
  /// no accent set, a remote session, an older Windows -- that "system" has to
  /// mean "system, or the brand colour if the system will not say". The brand
  /// colour is no longer a choice of its own, only this fallback and the first
  /// of the swatches.
  ///
  /// [nowPlaying] is the colour taken from the current track's artwork, and is
  /// null with nothing loaded or nothing to take it from. It survives a pause:
  /// what is loaded is still what is playing as far as this is concerned, and
  /// an app that changed colour every time somebody stopped a song would be
  /// unbearable.
  Color seed(Color? systemAccent, {Color? nowPlaying}) => switch (accent) {
        AccentSource.system => systemAccent ?? marmeladeSeed,
        AccentSource.custom => customAccent,
        // Falls back the way "system" does, since an empty queue has no
        // colour to offer and the app still has to be some colour.
        AccentSource.adaptive => nowPlaying ?? systemAccent ?? marmeladeSeed,
      };

  ThemePreference copyWith({
    ThemeMode? mode,
    AccentSource? accent,
    Color? customAccent,
    ContrastLevel? contrast,
    PaletteVariant? variant,
  }) =>
      ThemePreference(
        mode: mode ?? this.mode,
        accent: accent ?? this.accent,
        customAccent: customAccent ?? this.customAccent,
        contrast: contrast ?? this.contrast,
        variant: variant ?? this.variant,
      );

  @override
  bool operator ==(Object other) =>
      other is ThemePreference &&
      other.mode == mode &&
      other.accent == accent &&
      other.customAccent == customAccent &&
      other.contrast == contrast &&
      other.variant == variant;

  @override
  int get hashCode =>
      Object.hash(mode, accent, customAccent, contrast, variant);
}

/// The colours offered when picking one by hand.
///
/// A fixed set rather than a colour wheel: every one of these is a seed that
/// Material's palette generation makes a readable scheme from, in both
/// brightnesses. A wheel would let someone pick a colour that produces grey
/// text on a grey background and leave them wondering what they broke.
const accentChoices = <({String name, Color color})>[
  (name: 'Marmalade', color: marmeladeSeed),
  (name: 'Ember', color: Color(0xFFD84315)),
  (name: 'Rose', color: Color(0xFFE0457B)),
  (name: 'Violet', color: Color(0xFF7C4DFF)),
  (name: 'Indigo', color: Color(0xFF3F51B5)),
  (name: 'Sky', color: Color(0xFF0288D1)),
  (name: 'Teal', color: Color(0xFF00897B)),
  (name: 'Moss', color: Color(0xFF558B2F)),
  (name: 'Amber', color: Color(0xFFFFA000)),
  (name: 'Slate', color: Color(0xFF546E7A)),
];

/// What to call a theme mode in the UI.
String themeModeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => 'Match Windows',
      ThemeMode.light => 'Light',
      ThemeMode.dark => 'Dark',
    };
