import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Where the palette's seed colour comes from.
enum AccentSource {
  /// The Windows accent colour, so the app matches the desktop it sits on.
  system('Windows accent'),

  /// marmelade's own orange.
  brand('marmelade'),

  /// A colour chosen here.
  custom('A colour I picked');

  const AccentSource(this.label);

  final String label;

  static AccentSource of(String name) =>
      AccentSource.values.where((s) => s.name == name).firstOrNull ??
      AccentSource.system;
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
  });

  final ThemeMode mode;
  final AccentSource accent;
  final Color customAccent;

  /// The seed to build the palette from.
  ///
  /// [systemAccent] is what the OS reported, which is null often enough --
  /// no accent set, a remote session, an older Windows -- that "system" has to
  /// mean "system, or the brand colour if the system will not say".
  Color seed(Color? systemAccent) => switch (accent) {
        AccentSource.system => systemAccent ?? marmeladeSeed,
        AccentSource.brand => marmeladeSeed,
        AccentSource.custom => customAccent,
      };

  ThemePreference copyWith({
    ThemeMode? mode,
    AccentSource? accent,
    Color? customAccent,
  }) =>
      ThemePreference(
        mode: mode ?? this.mode,
        accent: accent ?? this.accent,
        customAccent: customAccent ?? this.customAccent,
      );

  @override
  bool operator ==(Object other) =>
      other is ThemePreference &&
      other.mode == mode &&
      other.accent == accent &&
      other.customAccent == customAccent;

  @override
  int get hashCode => Object.hash(mode, accent, customAccent);
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
