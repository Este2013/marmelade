import '../text/normalize.dart';
import 'credit_tokenizer.dart';
import 'separator.dart';

/// Names that mark a compilation rather than naming a performer.
const compilationMarkers = <String>{
  'various artists',
  'various',
  'va',
  'v a',
  'compilation',
  'unknown artist',
  'unknown',
  'no artist',
};

/// What the resolver knows about the artists already in the library.
///
/// An interface rather than a database call so the resolution rules can be
/// tested exhaustively without a database.
abstract interface class ArtistVocabulary {
  /// Ids of artists whose canonical name or any alias folds to [key].
  ///
  /// More than one id means the name is genuinely ambiguous in this library.
  List<int> idsForKey(String key);

  /// Looser lookup ignoring spacing, so "AC/DC", "AC DC" and "ACDC" meet.
  List<int> idsForCompactKey(String compact);

  /// Whether any artist matching [key] is flagged as never-split.
  bool isProtected(String key);
}

/// Corpus-wide evidence about how credit strings are used across the library.
///
/// This is what lets the resolver be smart rather than merely regex-driven. If
/// "Camellia" and "Nanahira" each appear on their own elsewhere in the
/// collection, then "Camellia x Nanahira" is almost certainly two artists. If
/// neither "Earth" nor "Wind" nor "Fire" ever appears alone, then
/// "Earth, Wind & Fire" is almost certainly one band.
abstract interface class CreditEvidence {
  /// How many times [key] appeared as an entire, unsplit credit string.
  int standaloneCount(String key);

  /// How many times [key] appeared as a segment of a credit that was split on
  /// an *unambiguous* separator.
  ///
  /// This is strong evidence that [key] is a real artist name, and it is the
  /// difference between working and not working on a real collection. If the
  /// library contains "Camellia VS Kobaryo" and "t+pazolite | Nanahira", then
  /// "Camellia" and "Nanahira" are both proven names even though neither ever
  /// headlines a track on its own - which is exactly what is needed to decide
  /// that "Camellia x Nanahira" is two people.
  int confirmedSegmentCount(String key);

  /// How many times [key] appeared as a segment of an *ambiguous* split.
  ///
  /// Weak evidence: it may just be a word inside a band name.
  int ambiguousSegmentCount(String key);
}

/// Convenience view over [CreditEvidence].
extension CreditEvidenceAttestation on CreditEvidence {
  /// How strongly the library believes [key] is a real artist name.
  int attestedCount(String key) =>
      standaloneCount(key) + confirmedSegmentCount(key);
}

/// A vocabulary that knows nothing. Useful for tests and first-run scans.
class EmptyArtistVocabulary implements ArtistVocabulary {
  const EmptyArtistVocabulary();
  @override
  List<int> idsForKey(String key) => const [];
  @override
  List<int> idsForCompactKey(String compact) => const [];
  @override
  bool isProtected(String key) => false;
}

/// Evidence that has seen nothing.
class EmptyCreditEvidence implements CreditEvidence {
  const EmptyCreditEvidence();
  @override
  int standaloneCount(String key) => 0;
  @override
  int confirmedSegmentCount(String key) => 0;
  @override
  int ambiguousSegmentCount(String key) => 0;
}

/// An in-memory vocabulary, built from name/alias pairs.
class MapArtistVocabulary implements ArtistVocabulary {
  MapArtistVocabulary();

  final _byKey = <String, List<int>>{};
  final _byCompact = <String, List<int>>{};
  final _protected = <String>{};

  /// Registers a name or alias for [artistId].
  void add(String name, int artistId, {bool neverSplit = false}) {
    final key = normalizeKey(name);
    if (key.isEmpty) return;
    (_byKey[key] ??= []).add(artistId);
    (_byCompact[compactKey(name)] ??= []).add(artistId);
    if (neverSplit) _protected.add(key);
  }

  @override
  List<int> idsForKey(String key) => _byKey[key] ?? const [];
  @override
  List<int> idsForCompactKey(String compact) => _byCompact[compact] ?? const [];
  @override
  bool isProtected(String key) => _protected.contains(key);
}

/// An in-memory evidence store, built by counting credit strings.
class MapCreditEvidence implements CreditEvidence {
  MapCreditEvidence();

  final _standalone = <String, int>{};
  final _confirmed = <String, int>{};
  final _ambiguous = <String, int>{};

  /// Records one credit string from the library.
  ///
  /// Call this for every credit string during the gathering pass, before
  /// resolving anything. The counts it builds are what let the resolver reason
  /// about the collection as a whole rather than one file at a time.
  void observe(String raw, CreditTokenizer tokenizer) {
    final tokens = tokenizer.tokenize(raw);
    if (tokens.segments.isEmpty) return;

    if (!tokens.didSplit) {
      _bump(_standalone, tokens.segments.single.key);
      return;
    }

    final trusted = tokens.separatorsUsed.any((s) => !s.isAmbiguous);
    if (!trusted) {
      // Only an ambiguously-split string is a plausible single name, so only
      // that form is worth counting as a standalone candidate. Counting
      // "Camellia VS Kobaryo" as a candidate name would be nonsense.
      _bump(_standalone, normalizeKey(raw));
    }
    for (final segment in tokens.segments) {
      _bump(trusted ? _confirmed : _ambiguous, segment.key);
    }
  }

  static void _bump(Map<String, int> into, String key) {
    if (key.isEmpty) return;
    into[key] = (into[key] ?? 0) + 1;
  }

  @override
  int standaloneCount(String key) => _standalone[key] ?? 0;
  @override
  int confirmedSegmentCount(String key) => _confirmed[key] ?? 0;
  @override
  int ambiguousSegmentCount(String key) => _ambiguous[key] ?? 0;
}

/// What the resolver decided to do with a credit string.
enum ResolutionOutcome {
  /// One artist. No separator was found, or the whole string is a known name.
  single,

  /// Split into several credits, with enough confidence to apply.
  split,

  /// Separators were found but deliberately not acted on, because the whole
  /// string is very likely a single real name.
  keptWhole,

  /// Genuinely uncertain. Nothing is applied; the credit is parked for review
  /// with [CreditResolution.alternative] holding the split that was declined.
  needsReview,

  /// The two halves name the same artist in different scripts, so one artist
  /// was produced carrying the other spelling as an alias.
  aliasPair,

  /// The string is a compilation marker such as "Various Artists", not an
  /// artist at all.
  compilation,

  /// Nothing usable in the input.
  empty,
}

/// One artist credit produced by resolution.
class ResolvedCredit {
  const ResolvedCredit({
    required this.creditedAs,
    required this.key,
    required this.role,
    required this.candidateArtistIds,
    this.aliases = const [],
  });

  /// The spelling used in the file, preserved for `credited_as`.
  final String creditedAs;

  /// [creditedAs] folded for matching.
  final String key;

  final SegmentRole role;

  /// Existing artists this credit could refer to.
  ///
  /// Empty means the artist does not exist yet and should be created. More
  /// than one entry means the name is ambiguous and a human should choose.
  final List<int> candidateArtistIds;

  /// The single artist this resolves to, or null if it must be created or is
  /// ambiguous.
  int? get artistId =>
      candidateArtistIds.length == 1 ? candidateArtistIds.single : null;

  /// Extra spellings to register against this artist.
  ///
  /// Populated when a credit string turned out to name one artist twice, such
  /// as a romanisation beside its native form.
  final List<String> aliases;

  bool get isNew => candidateArtistIds.isEmpty;
  bool get isAmbiguous => candidateArtistIds.length > 1;

  @override
  String toString() => 'ResolvedCredit("$creditedAs", $role, '
      'ids: $candidateArtistIds)';
}

/// The outcome of resolving one credit string.
class CreditResolution {
  const CreditResolution({
    required this.raw,
    required this.outcome,
    required this.credits,
    required this.confidence,
    required this.reason,
    this.alternative = const [],
  });

  final String raw;
  final ResolutionOutcome outcome;

  /// The credits to apply. For [ResolutionOutcome.needsReview] this holds the
  /// conservative interpretation (the whole string as one artist).
  final List<ResolvedCredit> credits;

  /// 0.0-1.0. Stored on each credit row so low-confidence data is visible.
  final double confidence;

  /// Why the resolver decided this, in plain words. Shown in the review queue
  /// and the debug tools; the single most useful thing when the matcher
  /// surprises someone.
  final String reason;

  /// The interpretation that was declined, when there was one. Lets the review
  /// UI offer "actually, do split this" in one click.
  final List<ResolvedCredit> alternative;

  /// Whether these credits can be written without asking the user.
  bool get isActionable =>
      outcome == ResolutionOutcome.single ||
      outcome == ResolutionOutcome.split ||
      outcome == ResolutionOutcome.keptWhole ||
      outcome == ResolutionOutcome.aliasPair;

  @override
  String toString() =>
      'CreditResolution($outcome, ${confidence.toStringAsFixed(2)}, '
      '$credits, reason: $reason)';
}

/// Options controlling how eager the resolver is to split.
class ResolverOptions {
  const ResolverOptions({
    this.aggressiveSplitting = false,
    this.wholeNameEvidenceThreshold = 2,
    this.strongAttestationThreshold = 2,
    this.detectAliasPairs = true,
  });

  /// When true, ambiguous separators are acted on without corroborating
  /// evidence. Faster to populate a library, more likely to mangle a band
  /// name. Exposed as a setting, off by default.
  final bool aggressiveSplitting;

  /// How many standalone appearances of the whole string are enough to
  /// conclude it is a real single name rather than an unsplit list.
  final int wholeNameEvidenceThreshold;

  /// How well attested one part must be before it outweighs a rarely-seen
  /// whole. Two sightings is enough: a real band name recurs, a one-off
  /// collaboration credit does not.
  final int strongAttestationThreshold;

  /// Whether to treat "Latin / native-script" pairs as one artist with an
  /// alias rather than two artists.
  final bool detectAliasPairs;

  /// Separators that join two spellings of the same name.
  ///
  /// Deliberately just the slash. It is the established convention for name
  /// variants, whereas a cross-script collaboration would be written with
  /// "x", a multiplication sign, "feat." or a comma - all of which stay
  /// genuine splits.
  static const aliasPairSeparators = {'/', '／'};
}

/// Turns raw credit strings into artist credits.
///
/// The rules, in order of precedence:
///
///  1. A string that exactly matches an existing artist or alias is that
///     artist. This is what makes "AC/DC" permanently safe once it exists.
///  2. A string with no separator is one artist.
///  3. A string containing an *unambiguous* separator is definitely a
///     composite - no real artist name contains " feat. " or "、" - and is
///     split outright.
///  4. A string containing only *ambiguous* separators needs corroboration,
///     because "Earth, Wind & Fire" is indistinguishable from a list by
///     shape alone. Corroboration means: the segments are known artists, or
///     the segments appear on their own elsewhere in the library.
///  5. Failing all that, nothing is applied and the credit is parked for
///     review. Guessing wrong is worse than asking.
class CreditResolver {
  CreditResolver({
    required this.tokenizer,
    this.vocabulary = const EmptyArtistVocabulary(),
    this.evidence = const EmptyCreditEvidence(),
    this.options = const ResolverOptions(),
  });

  final CreditTokenizer tokenizer;
  final ArtistVocabulary vocabulary;
  final CreditEvidence evidence;
  final ResolverOptions options;

  CreditResolution resolve(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.empty,
        credits: const [],
        confidence: 1,
        reason: 'empty credit string',
      );
    }

    final wholeKey = normalizeKey(trimmed);

    if (compilationMarkers.contains(wholeKey)) {
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.compilation,
        credits: const [],
        confidence: 1,
        reason: 'recognised compilation marker, not an artist',
      );
    }

    // Rule 1: the whole string is already a known artist or alias.
    final wholeMatches = vocabulary.idsForKey(wholeKey);
    if (wholeMatches.isNotEmpty) {
      return _single(
        raw: raw,
        text: trimmed,
        key: wholeKey,
        ids: wholeMatches,
        confidence: 1,
        reason: 'matches existing artist exactly',
      );
    }
    if (vocabulary.isProtected(wholeKey)) {
      return _single(
        raw: raw,
        text: trimmed,
        key: wholeKey,
        ids: const [],
        confidence: 1,
        reason: 'name is flagged never-split',
      );
    }

    final tokens = tokenizer.tokenize(trimmed);

    // Rule 2: nothing to split.
    if (tokens.segments.isEmpty) {
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.empty,
        credits: const [],
        confidence: 1,
        reason: 'no usable text after cleaning',
      );
    }
    if (!tokens.didSplit) {
      final segment = tokens.segments.single;
      final ids = _lookup(segment.key, segment.text);
      return _single(
        raw: raw,
        text: segment.text,
        key: segment.key,
        ids: ids,
        confidence: ids.isEmpty ? 0.9 : 1.0,
        reason: ids.isEmpty
            ? 'single name, not yet in the library'
            : 'single name, matched existing artist',
      );
    }

    final split = [
      for (final segment in tokens.segments)
        ResolvedCredit(
          creditedAs: segment.text,
          key: segment.key,
          role: segment.role,
          candidateArtistIds: _lookup(segment.key, segment.text),
        ),
    ];

    // Rule 3: an unambiguous separator settles it.
    if (tokens.isUnambiguous) {
      final known = split.where((c) => !c.isNew).length;
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.split,
        credits: split,
        confidence: 0.9 + 0.1 * (known / split.length),
        reason: 'split on unambiguous separator '
            '${_describe(tokens.separatorsUsed)}',
      );
    }

    // A mix of ambiguous and unambiguous separators still settles it: no
    // single artist is called "A, B feat. C".
    if (tokens.separatorsUsed.any((s) => !s.isAmbiguous)) {
      final known = split.where((c) => !c.isNew).length;
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.split,
        credits: split,
        confidence: 0.85 + 0.1 * (known / split.length),
        reason: 'contains the unambiguous separator '
            '${_describe(tokens.separatorsUsed.where((s) => !s.isAmbiguous))}, '
            'so the whole string cannot be one name',
      );
    }

    // Rule 4: ambiguous separators only. Look for corroboration.
    return _resolveAmbiguous(raw, trimmed, wholeKey, tokens, split);
  }

  CreditResolution _resolveAmbiguous(
    String raw,
    String trimmed,
    String wholeKey,
    CreditTokenization tokens,
    List<ResolvedCredit> split,
  ) {
    // Two spellings of one name, not two artists.
    final aliasPair = _tryAliasPair(raw, tokens, split);
    if (aliasPair != null) return aliasPair;

    if (options.aggressiveSplitting) {
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.split,
        credits: split,
        confidence: 0.6,
        reason: 'aggressive splitting is enabled',
      );
    }

    /// How strongly the library vouches for one part being a real name.
    int strength(ResolvedCredit c) =>
        c.isNew ? evidence.attestedCount(c.key) : 1 + evidence.attestedCount(c.key);

    final supported = split.where((c) => strength(c) > 0).length;
    final total = split.length;
    final wholeEvidence = evidence.standaloneCount(wholeKey);

    // Every part is independently attested. This is the "Camellia x Nanahira"
    // case, and it is the common one in a real collection.
    if (supported == total) {
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.split,
        credits: split,
        confidence: 0.9,
        reason: 'every part is a known artist or is attested elsewhere in the '
            'library',
      );
    }

    // Weigh the parts against the whole. A real band name recurs; a one-off
    // collaboration credit does not. So a well-established artist appearing
    // beside an unknown name, in a string seen only once, is a collaboration.
    final strongest = split.fold(0, (m, c) => strength(c) > m ? strength(c) : m);
    if (strongest >= options.strongAttestationThreshold &&
        wholeEvidence <= 1 &&
        supported >= 1) {
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.split,
        credits: split,
        confidence: 0.8,
        reason: 'one part is well attested ($strongest sightings) while the '
            'whole string appears only $wholeEvidence time'
            '${wholeEvidence == 1 ? "" : "s"}, so this reads as a '
            'collaboration rather than a name',
      );
    }

    // The unsplit string keeps turning up on its own, and its parts do not.
    // That is what a real name looks like.
    if (wholeEvidence >= options.wholeNameEvidenceThreshold && supported == 0) {
      return _single(
        raw: raw,
        text: trimmed,
        key: wholeKey,
        ids: const [],
        confidence: 0.85,
        reason: 'the whole string appears $wholeEvidence times as a credit of '
            'its own while none of its parts appear elsewhere, so it reads as '
            'one name',
        outcome: ResolutionOutcome.keptWhole,
        alternative: split,
      );
    }

    // A clear majority is attested.
    if (supported >= 2 && supported * 2 >= total) {
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.split,
        credits: split,
        confidence: 0.75,
        reason: '$supported of $total parts are known artists or are attested '
            'elsewhere',
      );
    }

    // A plain comma- or semicolon-delimited list of three or more reads as a
    // list. Note the deliberate exclusion of conjunctions: "X, Y & Z" is the
    // classic English band-name shape and must not be caught here.
    final onlyListPunctuation = tokens.separatorsUsed
        .every((s) => s.token == ',' || s.token == ';' || s.token == '，');
    if (onlyListPunctuation && total >= 3) {
      return CreditResolution(
        raw: raw,
        outcome: ResolutionOutcome.split,
        credits: split,
        confidence: 0.65,
        reason: '$total comma-separated parts reads as a list rather than a '
            'name',
      );
    }

    return CreditResolution(
      raw: raw,
      outcome: ResolutionOutcome.needsReview,
      credits: [
        ResolvedCredit(
          creditedAs: trimmed,
          key: wholeKey,
          role: SegmentRole.main,
          candidateArtistIds: const [],
        ),
      ],
      confidence: 0.4,
      reason: 'separator ${_describe(tokens.separatorsUsed)} also occurs inside '
          'real names, and nothing corroborates a split here '
          '($supported of $total parts attested)',
      alternative: split,
    );
  }

  /// Recognises "Latin / native-script" as one artist under two spellings.
  ///
  /// A slash between a Latin name and a CJK one is the established way of
  /// writing a name and its romanisation, not a collaboration - a real
  /// collaboration would use "x", a multiplication sign, "feat." or a comma,
  /// all of which are handled as splits before this is ever reached.
  ///
  /// Resolving it this way is what makes a native-script artist reachable from
  /// a Latin keyboard for free, instead of producing two half-populated artist
  /// pages for the same person.
  CreditResolution? _tryAliasPair(
    String raw,
    CreditTokenization tokens,
    List<ResolvedCredit> split,
  ) {
    if (!options.detectAliasPairs) return null;
    if (split.length != 2) return null;
    if (split.any((c) => c.role != SegmentRole.main)) return null;
    if (!tokens.separatorsUsed
        .every((s) => ResolverOptions.aliasPairSeparators.contains(s.token))) {
      return null;
    }

    final first = split.first;
    final second = split.last;
    // Exactly one side must be native-script for this to be a spelling pair.
    if (containsCjk(first.creditedAs) == containsCjk(second.creditedAs)) {
      return null;
    }

    // If one spelling is already a known artist, that one is canonical.
    final primary = !first.isNew
        ? first
        : !second.isNew
            ? second
            : first;
    final secondary = primary == first ? second : first;

    return CreditResolution(
      raw: raw,
      outcome: ResolutionOutcome.aliasPair,
      credits: [
        ResolvedCredit(
          creditedAs: primary.creditedAs,
          key: primary.key,
          role: SegmentRole.main,
          candidateArtistIds: primary.candidateArtistIds,
          aliases: [secondary.creditedAs],
        ),
      ],
      confidence: 0.75,
      reason: 'a slash between a Latin and a native-script name reads as one '
          'artist under two spellings, so "${secondary.creditedAs}" becomes an '
          'alias of "${primary.creditedAs}"',
      alternative: split,
    );
  }

  /// Looks a segment up by exact key, then by the looser spacing-insensitive
  /// key.
  List<int> _lookup(String key, String text) {
    final exact = vocabulary.idsForKey(key);
    if (exact.isNotEmpty) return exact;
    return vocabulary.idsForCompactKey(compactKey(text));
  }

  CreditResolution _single({
    required String raw,
    required String text,
    required String key,
    required List<int> ids,
    required double confidence,
    required String reason,
    ResolutionOutcome outcome = ResolutionOutcome.single,
    List<ResolvedCredit> alternative = const [],
  }) {
    return CreditResolution(
      raw: raw,
      outcome: outcome,
      credits: [
        ResolvedCredit(
          creditedAs: text,
          key: key,
          role: SegmentRole.main,
          candidateArtistIds: ids,
        ),
      ],
      confidence: confidence,
      reason: reason,
      alternative: alternative,
    );
  }

  String _describe(Iterable<SeparatorSpec> separators) {
    final tokens = separators.map((s) => '"${s.token}"').toSet();
    return tokens.join(', ');
  }
}
