import 'package:flutter/material.dart';

/// The icons a tag category can wear.
///
/// A fixed list of `const IconData`, and the stored value is a code point that
/// is looked up *in this list*. It is never fed to `IconData` directly:
/// Flutter's release build strips unused glyphs from the icon font, and an
/// IconData built from a runtime number defeats that -- the tool cannot see
/// which glyphs are reachable, so it keeps the whole font or refuses to build.
///
/// Chosen for what a music library actually sorts by, rather than as a general
/// icon browser. A category nobody can find an icon for gets the default.
const tagCategoryIcons = <({IconData icon, String name})>[
  (icon: Icons.label_outline, name: 'Label'),
  (icon: Icons.music_note_outlined, name: 'Genre'),
  (icon: Icons.translate, name: 'Language'),
  (icon: Icons.mood, name: 'Mood'),
  (icon: Icons.bolt_outlined, name: 'Energy'),
  (icon: Icons.favorite_outline, name: 'Love'),
  (icon: Icons.star_outline, name: 'Quality'),
  (icon: Icons.event_outlined, name: 'Occasion'),
  (icon: Icons.access_time, name: 'Era'),
  (icon: Icons.mic_none_outlined, name: 'Vocals'),
  (icon: Icons.piano_outlined, name: 'Instrument'),
  (icon: Icons.headphones_outlined, name: 'Listening'),
  (icon: Icons.movie_outlined, name: 'Soundtrack'),
  (icon: Icons.sports_esports_outlined, name: 'Games'),
  (icon: Icons.public, name: 'Region'),
  (icon: Icons.auto_awesome_outlined, name: 'Special'),
  (icon: Icons.nightlight_outlined, name: 'Night'),
  (icon: Icons.wb_sunny_outlined, name: 'Day'),
  (icon: Icons.fitness_center_outlined, name: 'Workout'),
  (icon: Icons.self_improvement_outlined, name: 'Calm'),
];

/// The icon stored for a category, or a sensible default.
///
/// Falls back rather than failing: a code point written by a later version, or
/// by hand in the database, should show *an* icon.
IconData tagCategoryIcon(int? codePoint) {
  if (codePoint == null) return Icons.label_outline;
  for (final entry in tagCategoryIcons) {
    if (entry.icon.codePoint == codePoint) return entry.icon;
  }
  return Icons.label_outline;
}

/// The colours a category can be given.
///
/// The same reasoning as the accent picker: a fixed set that stays legible on
/// both themes, rather than a wheel that lets someone choose grey on grey.
const tagCategoryColors = <({String name, Color color})>[
  (name: 'Orange', color: Color(0xFFE8730C)),
  (name: 'Red', color: Color(0xFFD84315)),
  (name: 'Pink', color: Color(0xFFE0457B)),
  (name: 'Violet', color: Color(0xFF7C4DFF)),
  (name: 'Indigo', color: Color(0xFF3F51B5)),
  (name: 'Sky', color: Color(0xFF0288D1)),
  (name: 'Teal', color: Color(0xFF00897B)),
  (name: 'Moss', color: Color(0xFF558B2F)),
  (name: 'Amber', color: Color(0xFFFFA000)),
  (name: 'Slate', color: Color(0xFF546E7A)),
];
