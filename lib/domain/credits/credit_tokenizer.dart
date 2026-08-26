import '../text/normalize.dart';
import 'separator.dart';

/// The role a tokenized segment carries, before it is matched to an artist.
enum SegmentRole {
  /// A co-equal lead artist.
  main,

  /// A guest credit.
  featured,

  /// Credited with a remix.
  remixer,
}

/// One artist-shaped piece of a credit string.
class CreditSegment {
  CreditSegment({
    required this.text,
    required this.role,
    required this.orderIndex,
  }) : key = normalizeKey(text);

  /// The segment as it appeared, trimmed. This is what gets stored as
  /// `credited_as`, so the original spelling survives.
  final String text;

  final SegmentRole role;

  /// Position within the original credit string, from zero.
  final int orderIndex;

  /// [text] folded for matching. See [normalizeKey].
  final String key;

  @override
  String toString() => 'CreditSegment("$text", $role)';
}

/// The result of splitting one credit string.
class CreditTokenization {
  const CreditTokenization({
    required this.raw,
    required this.segments,
    required this.separatorsUsed,
  });

  /// The input, unmodified.
  final String raw;

  /// The pieces, in the order they appeared. A string with no separators
  /// yields exactly one segment.
  final List<CreditSegment> segments;

  /// Which separators actually matched.
  final List<SeparatorSpec> separatorsUsed;

  /// Whether any separator was found at all.
  bool get didSplit => segments.length > 1;

  /// Whether every separator used is one that real artist names do not
  /// contain.
  ///
  /// When true, the split can be trusted on its own. When false, the resolver
  /// needs corroborating evidence before acting: "Earth, Wind & Fire" tokenizes
  /// into three plausible-looking segments and is nonetheless one band.
  bool get isUnambiguous =>
      separatorsUsed.isNotEmpty && separatorsUsed.every((s) => !s.isAmbiguous);

  @override
  String toString() => 'CreditTokenization($raw -> $segments)';
}

/// Splits raw credit strings into candidate artist segments.
///
/// Purely lexical: it knows nothing about which artists exist. Deciding
/// whether a split should actually be applied is the resolver's job, because
/// that needs knowledge of the library. Keeping the two apart is what makes
/// this class trivially testable.
class CreditTokenizer {
  CreditTokenizer(Iterable<SeparatorSpec> separators)
      : _separators = separators.where((s) => s.enabled).toList() {
    // Longest first, so "feat." wins over "feat" and "vs." over "vs".
    _separators.sort((a, b) => b.token.length.compareTo(a.token.length));
    _pattern = _buildPattern(_separators);
  }

  /// Builds a tokenizer with the separators the app ships with.
  factory CreditTokenizer.withDefaults() =>
      CreditTokenizer(defaultSeparators);

  final List<SeparatorSpec> _separators;
  late final RegExp? _pattern;

  /// Characters that decorate a credit without contributing to it.
  ///
  /// Folded to spaces rather than removed, so `"A (feat. B)"` becomes
  /// `"A  feat. B "` and the whitespace-guarded `feat.` still matches.
  static final _brackets = RegExp(r'[\(\)\[\]\{\}【】「」『』（）〈〉]');

  static final _whitespace = RegExp(r'\s+');

  static RegExp? _buildPattern(List<SeparatorSpec> separators) {
    if (separators.isEmpty) return null;
    final alternatives = separators.map((s) {
      final escaped = RegExp.escape(s.token);
      if (!s.requiresSpaces) return escaped;
      // Must stand alone. Lookarounds keep the surrounding whitespace out of
      // the match, so adjacent separators cannot swallow each other.
      return r'(?<=^|\s)' + escaped + r'(?=\s|$)';
    });
    return RegExp(alternatives.join('|'), caseSensitive: false);
  }

  /// Splits [raw] into segments.
  CreditTokenization tokenize(String raw) {
    final cleaned = raw.replaceAll(_brackets, ' ').trim();
    if (cleaned.isEmpty) {
      return CreditTokenization(
        raw: raw,
        segments: _finalize([_Piece(cleaned, SegmentRole.main)]),
        separatorsUsed: const [],
      );
    }

    final pattern = _pattern;
    if (pattern == null) {
      return CreditTokenization(
        raw: raw,
        segments: _finalize([_Piece(cleaned, SegmentRole.main)]),
        separatorsUsed: const [],
      );
    }

    final pieces = <_Piece>[];
    final used = <SeparatorSpec>[];
    var role = SegmentRole.main;
    var cursor = 0;

    for (final match in pattern.allMatches(cleaned)) {
      pieces.add(_Piece(cleaned.substring(cursor, match.start), role));
      cursor = match.end;

      final spec = _specFor(match.group(0)!);
      if (spec != null) {
        used.add(spec);
        // The role is sticky: everything after "feat." stays a guest credit
        // until something else changes it.
        role = switch (spec.kind) {
          SeparatorKind.split => role,
          SeparatorKind.featured => SegmentRole.featured,
          SeparatorKind.remix => SegmentRole.remixer,
        };
      }
    }
    pieces.add(_Piece(cleaned.substring(cursor), role));

    return CreditTokenization(
      raw: raw,
      segments: _finalize(pieces),
      separatorsUsed: used,
    );
  }

  SeparatorSpec? _specFor(String matched) {
    final lowered = matched.toLowerCase();
    for (final s in _separators) {
      if (s.token.toLowerCase() == lowered) return s;
    }
    return null;
  }

  /// Trims, drops empties, and collapses repeats.
  ///
  /// A name appearing twice keeps its strongest role, so
  /// "A feat. A" does not produce a guest credit that shadows the lead.
  List<CreditSegment> _finalize(List<_Piece> pieces) {
    final byKey = <String, CreditSegment>{};
    final ordered = <CreditSegment>[];

    for (final piece in pieces) {
      final text = piece.text.replaceAll(_whitespace, ' ').trim();
      if (text.isEmpty) continue;
      final key = normalizeKey(text);
      if (key.isEmpty) continue;

      final existing = byKey[key];
      if (existing == null) {
        final segment = CreditSegment(
          text: text,
          role: piece.role,
          orderIndex: ordered.length,
        );
        byKey[key] = segment;
        ordered.add(segment);
      } else if (piece.role.index < existing.role.index) {
        // Stronger role wins; replace in place to keep ordering.
        final replacement = CreditSegment(
          text: existing.text,
          role: piece.role,
          orderIndex: existing.orderIndex,
        );
        byKey[key] = replacement;
        ordered[ordered.indexOf(existing)] = replacement;
      }
    }
    return ordered;
  }
}

class _Piece {
  const _Piece(this.text, this.role);
  final String text;
  final SegmentRole role;
}
