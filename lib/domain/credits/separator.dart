/// Credit separators: the tokens that turn one artist field into several
/// artists.
library;

/// How a separator token changes the credits that follow it.
enum SeparatorKind {
  /// Splits into co-equal main artists ("A x B", "A, B").
  split,

  /// Everything after it is a featured credit ("A feat. B").
  featured,

  /// Everything after it is a remixer ("A remixed by B").
  remix,
}

/// One separator token and how far it can be trusted.
class SeparatorSpec {
  const SeparatorSpec(
    this.token,
    this.kind, {
    this.requiresSpaces = false,
    this.isAmbiguous = false,
    this.enabled = true,
  });

  /// The literal token, matched case-insensitively.
  final String token;

  final SeparatorKind kind;

  /// Whether the token only counts when surrounded by whitespace or a string
  /// boundary.
  ///
  /// This is a *lexical* guard against false positives inside a single word.
  /// It is what stops `x` from shredding "Maxence", `+` from breaking
  /// "t+pazolite", and `/` from destroying "AC/DC".
  final bool requiresSpaces;

  /// Whether real artist names are known to contain this token.
  ///
  /// Distinct from [requiresSpaces], and the distinction matters. `,` needs no
  /// surrounding spaces to be a separator, yet "Earth, Wind & Fire" is one
  /// band. Conversely `|` is whitespace-delimited in practice but essentially
  /// never part of a name.
  ///
  /// Ambiguous separators are not trusted on their own: the resolver requires
  /// corroborating evidence before acting on them, and parks the credit for
  /// review when it finds none.
  final bool isAmbiguous;

  final bool enabled;

  SeparatorSpec copyWith({bool? enabled}) => SeparatorSpec(
        token,
        kind,
        requiresSpaces: requiresSpaces,
        isAmbiguous: isAmbiguous,
        enabled: enabled ?? this.enabled,
      );

  @override
  String toString() => 'SeparatorSpec($token, $kind, '
      'spaces: $requiresSpaces, ambiguous: $isAmbiguous)';
}

/// The separator set the app ships with.
///
/// Order matters only in that longer tokens must be tried before their own
/// prefixes ("feat." before "feat", "vs." before "vs"); the tokenizer sorts by
/// length, so this list is free to read in a sensible order.
const defaultSeparators = <SeparatorSpec>[
  // ---- Unambiguous collaboration marks ----
  // These essentially never appear inside a real artist name, so they neither
  // need surrounding whitespace nor corroborating evidence.
  SeparatorSpec('×', SeparatorKind.split),
  SeparatorSpec('✕', SeparatorKind.split),
  SeparatorSpec('✖', SeparatorKind.split),
  SeparatorSpec('、', SeparatorKind.split), // ideographic comma
  SeparatorSpec('，', SeparatorKind.split), // full-width comma
  SeparatorSpec('|', SeparatorKind.split),
  SeparatorSpec(';', SeparatorKind.split),

  // ---- Ambiguous ----
  // Real names contain all of these. Whitespace-guarded where a name could
  // contain them mid-word, and always requiring evidence before a split.
  SeparatorSpec(',', SeparatorKind.split, isAmbiguous: true),
  SeparatorSpec('＆', SeparatorKind.split, isAmbiguous: true),
  SeparatorSpec('x', SeparatorKind.split,
      requiresSpaces: true, isAmbiguous: true),
  SeparatorSpec('&', SeparatorKind.split,
      requiresSpaces: true, isAmbiguous: true),
  SeparatorSpec('+', SeparatorKind.split,
      requiresSpaces: true, isAmbiguous: true),
  SeparatorSpec('/', SeparatorKind.split,
      requiresSpaces: true, isAmbiguous: true),
  SeparatorSpec('and', SeparatorKind.split,
      requiresSpaces: true, isAmbiguous: true),

  // "vs" reads as a separator far more reliably than "and" does, but band
  // names do exist that contain it, so it stays whitespace-guarded.
  SeparatorSpec('versus', SeparatorKind.split, requiresSpaces: true),
  SeparatorSpec('vs.', SeparatorKind.split, requiresSpaces: true),
  SeparatorSpec('vs', SeparatorKind.split, requiresSpaces: true),

  // ---- Featured credits ----
  SeparatorSpec('featuring', SeparatorKind.featured, requiresSpaces: true),
  SeparatorSpec('feat.', SeparatorKind.featured, requiresSpaces: true),
  SeparatorSpec('feat', SeparatorKind.featured, requiresSpaces: true),
  SeparatorSpec('ft.', SeparatorKind.featured, requiresSpaces: true),
  SeparatorSpec('ft', SeparatorKind.featured, requiresSpaces: true),
  SeparatorSpec('with', SeparatorKind.featured,
      requiresSpaces: true, isAmbiguous: true),

  // ---- Remix credits ----
  SeparatorSpec('remixed by', SeparatorKind.remix, requiresSpaces: true),
];
