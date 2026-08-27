import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/domain/credits/credit_resolver.dart';
import 'package:marmelade/domain/credits/credit_tokenizer.dart';
import 'package:marmelade/domain/text/normalize.dart';

void main() {
  final tokenizer = CreditTokenizer.withDefaults();

  group('normalizeKey', () {
    test('folds case, accents and punctuation', () {
      expect(normalizeKey('Björk'), 'bjork');
      expect(normalizeKey('Sigur Rós'), 'sigur ros');
      expect(normalizeKey('MOTÖRHEAD'), 'motorhead');
      // Punctuation becomes a word break rather than vanishing.
      expect(normalizeKey('AC/DC'), 'ac dc');
      expect(normalizeKey('t+pazolite'), 't pazolite');
    });

    test('folds full-width Latin, which Japanese tag editors emit', () {
      expect(normalizeKey('ＲＥＯＬ'), 'reol');
      expect(normalizeKey('ＧＩＧＡ'), 'giga');
    });

    test('folds hiragana onto katakana so both spellings meet', () {
      expect(normalizeKey('ぴのきおぴー'), normalizeKey('ピノキオピー'));
    });

    test('keeps CJK content intact', () {
      expect(normalizeKey('初音ミク'), '初音ミク');
      expect(normalizeKey('  初音ミク  '), '初音ミク');
    });

    test('collapses whitespace and trims', () {
      expect(normalizeKey('  The   Beatles '), 'the beatles');
    });

    test('compactKey ignores spacing entirely', () {
      expect(compactKey('AC/DC'), 'acdc');
      expect(compactKey('AC DC'), 'acdc');
      expect(compactKey('ACDC'), 'acdc');
    });

    test('sortKeyFor moves a leading article to the end', () {
      expect(sortKeyFor('The Beatles'), 'beatles the');
      expect(sortKeyFor('A Perfect Circle'), 'perfect circle a');
      expect(sortKeyFor('Camellia'), 'camellia');
    });

    test('containsCjk detects kana, ideographs and hangul', () {
      expect(containsCjk('ピノキオピー'), isTrue);
      expect(containsCjk('初音ミク'), isTrue);
      expect(containsCjk('Camellia'), isFalse);
      expect(containsCjk('Björk'), isFalse);
    });
  });

  group('tokenizer', () {
    List<String> segmentsOf(String raw) =>
        tokenizer.tokenize(raw).segments.map((s) => s.text).toList();

    test('splits on unambiguous collaboration marks', () {
      expect(segmentsOf('REOL ✕ Giga'), ['REOL', 'Giga']);
      expect(segmentsOf('REOL×Giga'), ['REOL', 'Giga']);
      expect(segmentsOf('初音ミク、重音テト'), ['初音ミク', '重音テト']);
      expect(segmentsOf('t+pazolite | Nanahira'), ['t+pazolite', 'Nanahira']);
    });

    test('splits on whitespace-guarded ambiguous marks', () {
      expect(segmentsOf('Camellia x Nanahira'), ['Camellia', 'Nanahira']);
      expect(segmentsOf('Camellia VS Kobaryo'), ['Camellia', 'Kobaryo']);
    });

    test('the whitespace guard protects names containing the token', () {
      // This is the whole point of requiresSpaces.
      expect(segmentsOf('Maxence Cyrin'), ['Maxence Cyrin']);
      expect(segmentsOf('AC/DC'), ['AC/DC']);
      expect(segmentsOf('t+pazolite'), ['t+pazolite']);
      expect(segmentsOf('Sixteen'), ['Sixteen']);
      expect(segmentsOf('Andrew Bird'), ['Andrew Bird']);
    });

    test('assigns the featured role after a feat. marker', () {
      final tokens = tokenizer.tokenize('PinocchioP feat. Kasane Teto');
      expect(tokens.segments.map((s) => s.text), ['PinocchioP', 'Kasane Teto']);
      expect(tokens.segments.map((s) => s.role),
          [SegmentRole.main, SegmentRole.featured]);
    });

    test('a dotted abbreviation does not need a space after it', () {
      // Real tags from the library: the period is the boundary, and demanding
      // whitespace after it left the whole field standing as one artist named
      // "Tomoki Hirata feat.Crystal Mint".
      final tokens = tokenizer.tokenize('Tomoki Hirata feat.Crystal Mint');
      expect(tokens.segments.map((s) => s.text),
          ['Tomoki Hirata', 'Crystal Mint']);
      expect(tokens.segments.map((s) => s.role),
          [SegmentRole.main, SegmentRole.featured]);
      expect(segmentsOf('Kuraine ft.Nanahira'), ['Kuraine', 'Nanahira']);
      expect(segmentsOf('Camellia vs.Kobaryo'), ['Camellia', 'Kobaryo']);
    });

    test('the left-hand guard still protects words ending in a marker', () {
      // Dropping the trailing guard must not make "feat." match inside a word.
      expect(segmentsOf('Agent Of Defeat.Exe'), ['Agent Of Defeat.Exe']);
      // Bare markers keep both guards, so these stay whole.
      expect(segmentsOf('Feats of Strength'), ['Feats of Strength']);
    });

    test('the featured role is sticky across later separators', () {
      final tokens =
          tokenizer.tokenize('A feat. B & C');
      expect(tokens.segments.map((s) => s.role), [
        SegmentRole.main,
        SegmentRole.featured,
        SegmentRole.featured,
      ]);
    });

    test('unwraps bracketed feature credits', () {
      final tokens = tokenizer.tokenize('PinocchioP (feat. Hatsune Miku)');
      expect(tokens.segments.map((s) => s.text),
          ['PinocchioP', 'Hatsune Miku']);
      expect(tokens.segments.last.role, SegmentRole.featured);
    });

    test('prefers the longer of two overlapping tokens', () {
      // "feat." must win over "feat", leaving no stray dot behind.
      expect(segmentsOf('A feat. B'), ['A', 'B']);
      expect(segmentsOf('A vs. B'), ['A', 'B']);
    });

    test('collapses a repeated name, keeping its strongest role', () {
      final tokens = tokenizer.tokenize('Camellia feat. Camellia');
      expect(tokens.segments, hasLength(1));
      expect(tokens.segments.single.role, SegmentRole.main);
    });

    test('reports whether the separators used were ambiguous', () {
      expect(tokenizer.tokenize('A × B').isUnambiguous, isTrue);
      expect(tokenizer.tokenize('A feat. B').isUnambiguous, isTrue);
      expect(tokenizer.tokenize('A & B').isUnambiguous, isFalse);
      expect(tokenizer.tokenize('A, B').isUnambiguous, isFalse);
      // No separators at all is not "unambiguous", it is "not a split".
      expect(tokenizer.tokenize('Solo').isUnambiguous, isFalse);
    });

    test('preserves the original spelling of each segment', () {
      final tokens = tokenizer.tokenize('ＲＥＯＬ ✕ Giga');
      expect(tokens.segments.first.text, 'ＲＥＯＬ');
      expect(tokens.segments.first.key, 'reol');
    });
  });

  group('resolver with an empty library', () {
    final resolver = CreditResolver(tokenizer: tokenizer);

    test('a lone name is a single new artist', () {
      final r = resolver.resolve('Bossfight');
      expect(r.outcome, ResolutionOutcome.single);
      expect(r.credits.single.creditedAs, 'Bossfight');
      expect(r.credits.single.isNew, isTrue);
    });

    test('splits on an unambiguous separator without any evidence', () {
      for (final raw in const [
        'REOL ✕ Giga',
        '初音ミク、重音テト',
        't+pazolite | Nanahira',
        'Camellia VS Kobaryo',
      ]) {
        final r = resolver.resolve(raw);
        expect(r.outcome, ResolutionOutcome.split, reason: raw);
        expect(r.credits, hasLength(2), reason: raw);
        expect(r.confidence, greaterThanOrEqualTo(0.85), reason: raw);
      }
    });

    test('a feat. marker proves the string cannot be one name', () {
      final r = resolver.resolve(
          'PinocchioP, Hatsune Miku feat. Kasane Teto');
      expect(r.outcome, ResolutionOutcome.split);
      expect(r.credits.map((c) => c.creditedAs),
          ['PinocchioP', 'Hatsune Miku', 'Kasane Teto']);
      expect(r.credits.map((c) => c.role), [
        SegmentRole.main,
        SegmentRole.main,
        SegmentRole.featured,
      ]);
    });

    test('refuses to guess on an ambiguous separator alone', () {
      // These are the cases that mangle libraries. With nothing to corroborate
      // a split, the resolver must ask rather than act.
      for (final raw in const [
        'Simon & Garfunkel',
        'Earth, Wind & Fire',
        'Camellia x Nanahira',
      ]) {
        final r = resolver.resolve(raw);
        expect(r.outcome, ResolutionOutcome.needsReview, reason: raw);
        // Nothing destructive is applied: the conservative reading is kept.
        expect(r.credits, hasLength(1), reason: raw);
        expect(r.credits.single.creditedAs, raw, reason: raw);
        // But the split is offered, so accepting it is one click.
        expect(r.alternative.length, greaterThan(1), reason: raw);
        expect(r.reason, isNotEmpty, reason: raw);
      }
    });

    test('a name containing a guarded token is never split', () {
      for (final raw in const ['AC/DC', 't+pazolite', 'Maxence Cyrin']) {
        final r = resolver.resolve(raw);
        expect(r.outcome, ResolutionOutcome.single, reason: raw);
        expect(r.credits.single.creditedAs, raw, reason: raw);
      }
    });

    test('recognises compilation markers as not-an-artist', () {
      for (final raw in const ['Various Artists', 'various', 'VA', 'Unknown']) {
        final r = resolver.resolve(raw);
        expect(r.outcome, ResolutionOutcome.compilation, reason: raw);
        expect(r.credits, isEmpty, reason: raw);
      }
    });

    test('handles empty and whitespace-only input', () {
      for (final raw in const ['', '   ', '()', ' - ']) {
        final r = resolver.resolve(raw);
        expect(r.outcome, ResolutionOutcome.empty, reason: '"$raw"');
        expect(r.credits, isEmpty, reason: '"$raw"');
      }
    });
  });

  group('resolver with a populated library', () {
    /// Builds a resolver whose library already knows [known] artists.
    CreditResolver withArtists(
      Map<String, int> known, {
      Set<String> protected = const {},
      ResolverOptions options = const ResolverOptions(),
    }) {
      final vocab = MapArtistVocabulary();
      known.forEach((name, id) => vocab.add(name, id,
          neverSplit: protected.contains(name)));
      return CreditResolver(
        tokenizer: tokenizer,
        vocabulary: vocab,
        options: options,
      );
    }

    test('an exactly-matching name wins over any splitting', () {
      // The decisive protection: once "Earth, Wind & Fire" exists as an
      // artist, its own name can never be split again.
      final resolver = withArtists({'Earth, Wind & Fire': 7});
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, ResolutionOutcome.single);
      expect(r.credits.single.artistId, 7);
      expect(r.confidence, 1.0);
    });

    test('splits an ambiguous separator once both parts are known', () {
      final resolver = withArtists({'Camellia': 1, 'Nanahira': 2});
      final r = resolver.resolve('Camellia x Nanahira');
      expect(r.outcome, ResolutionOutcome.split);
      expect(r.credits.map((c) => c.artistId), [1, 2]);
      expect(r.confidence, greaterThanOrEqualTo(0.85));
    });

    test('one known part is enough to split', () {
      // The policy this library is tuned for: a known artist inside the string
      // means the field is a list. Requiring every part to be attested left
      // credits like "LukHash x Shirobon" unsplit even though LukHash has his
      // own albums here, which is the failure the app exists to prevent.
      final resolver = withArtists({'Fire': 3});
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, ResolutionOutcome.split);
      expect(r.reason, contains('is a known artist'));
    });

    test('the conservative rule still refuses, when asked for', () {
      // The cost of the rule above is a band name whose words include a known
      // artist. Turning the option off restores review-instead-of-guess.
      final resolver = withArtists({'Fire': 3},
          options: const ResolverOptions(splitOnAnyAttestedPart: false));
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, ResolutionOutcome.needsReview);
    });

    test('an existing artist row protects a name permanently', () {
      // This is what bounds the risk: correct a mis-split once and the exact
      // match in rule 1 keeps it corrected, whatever the parts are attested as.
      final resolver = withArtists({'Fire': 3, 'Earth, Wind & Fire': 9});
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, isNot(ResolutionOutcome.split));
      expect(r.credits.single.artistId, 9);
    });

    test('splits when a clear majority of parts are known', () {
      final resolver = withArtists({'Camellia': 1, 'Nanahira': 2});
      final r = resolver.resolve('Camellia, Nanahira & Kobaryo');
      expect(r.outcome, ResolutionOutcome.split);
      expect(r.credits, hasLength(3));
      expect(r.credits.last.isNew, isTrue);
    });

    test('an alias resolves to the same artist as the canonical name', () {
      final vocab = MapArtistVocabulary()
        ..add('ピノキオピー', 42)
        ..add('PinocchioP', 42);
      final resolver = CreditResolver(tokenizer: tokenizer, vocabulary: vocab);

      // Both spellings, and the hiragana form, land on artist 42.
      for (final spelling in const ['ピノキオピー', 'PinocchioP', 'pinocchiop']) {
        final r = resolver.resolve(spelling);
        expect(r.credits.single.artistId, 42, reason: spelling);
      }
    });

    test('a spaced spelling of a known name matches it rather than splitting',
        () {
      final resolver = withArtists({'AC/DC': 9});
      // "AC/DC" and "AC / DC" both fold to "ac dc", so normalisation catches
      // this before the splitter ever gets a chance.
      final r = resolver.resolve('AC / DC');
      expect(r.outcome, ResolutionOutcome.single);
      expect(r.credits.single.artistId, 9);
    });

    test('the never-split flag protects a name that has no artist row yet', () {
      final resolver = CreditResolver(
        tokenizer: tokenizer,
        vocabulary: _ProtectedOnlyVocabulary({'earth wind fire'}),
      );
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, ResolutionOutcome.single);
      expect(r.credits.single.creditedAs, 'Earth, Wind & Fire');
      expect(r.credits.single.isNew, isTrue);
      expect(r.reason, contains('never-split'));
    });

    test('reports an ambiguous name instead of picking one', () {
      final vocab = MapArtistVocabulary()
        ..add('Prince', 1)
        ..add('Prince', 2);
      final resolver = CreditResolver(tokenizer: tokenizer, vocabulary: vocab);
      final r = resolver.resolve('Prince');
      expect(r.credits.single.isAmbiguous, isTrue);
      expect(r.credits.single.artistId, isNull);
      expect(r.credits.single.candidateArtistIds, [1, 2]);
    });

    test('falls back to spacing-insensitive matching', () {
      final resolver = withArtists({'ACDC': 5});
      final r = resolver.resolve('AC DC');
      expect(r.credits.single.artistId, 5);
    });
  });

  group('resolver using corpus evidence', () {
    /// Builds evidence by observing a whole library's worth of credit strings,
    /// exactly as the two-phase indexer does.
    CreditResolver withCorpus(List<String> corpus) {
      final ev = MapCreditEvidence();
      for (final raw in corpus) {
        ev.observe(raw, tokenizer);
      }
      return CreditResolver(tokenizer: tokenizer, evidence: ev);
    }

    test('splits when both parts are attested alone elsewhere', () {
      // No artist rows exist yet - this is a cold first scan. The evidence
      // that "Camellia" and "Nanahira" each headline their own tracks is
      // enough to conclude the collaboration is two people.
      final resolver = withCorpus([
        'Camellia',
        'Camellia',
        'Nanahira',
        'Camellia x Nanahira',
      ]);
      final r = resolver.resolve('Camellia x Nanahira');
      expect(r.outcome, ResolutionOutcome.split);
      expect(r.reason, contains('attested elsewhere'));
    });

    test('keeps a band name whole when no part is ever attested alone', () {
      // A greatest-hits folder: the name recurs, its words never stand alone.
      final resolver = withCorpus([
        'Earth, Wind & Fire',
        'Earth, Wind & Fire',
        'Earth, Wind & Fire',
      ]);
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, ResolutionOutcome.keptWhole);
      expect(r.credits.single.creditedAs, 'Earth, Wind & Fire');
      expect(r.reason, contains('one name'));
      // The split is still offered if the user disagrees.
      expect(r.alternative, hasLength(3));
    });

    test('one sighting is not enough to conclude anything', () {
      final resolver = withCorpus(['Simon & Garfunkel']);
      final r = resolver.resolve('Simon & Garfunkel');
      expect(r.outcome, ResolutionOutcome.needsReview);
    });

    test('a name proven by an unambiguous split counts as evidence', () {
      // The flagship case, and the one a naive implementation gets wrong.
      // Neither "Camellia" nor "Nanahira" ever headlines a track here; each is
      // only ever known from a collaboration that used a trustworthy
      // separator. That is still proof the names are real, so the ambiguous
      // " x " collaboration must split.
      final resolver = withCorpus([
        'Camellia VS Kobaryo',
        't+pazolite | Nanahira',
        'Camellia x Nanahira',
        'Camellia x Nanahira',
      ]);
      final r = resolver.resolve('Camellia x Nanahira');
      expect(r.outcome, ResolutionOutcome.split);
      expect(r.credits.map((c) => c.creditedAs), ['Camellia', 'Nanahira']);
    });

    test('an unambiguous split does not make the whole string a name', () {
      // "Camellia VS Kobaryo" must never be counted as a candidate single
      // name, or it could later be defended as one.
      final ev = MapCreditEvidence();
      ev.observe('Camellia VS Kobaryo', tokenizer);
      expect(ev.standaloneCount(normalizeKey('Camellia VS Kobaryo')), 0);
      expect(ev.confirmedSegmentCount('camellia'), 1);
      expect(ev.confirmedSegmentCount('kobaryo'), 1);

      // An ambiguous one, by contrast, is a plausible name and is counted.
      ev.observe('Earth, Wind & Fire', tokenizer);
      expect(ev.standaloneCount('earth wind fire'), 1);
      expect(ev.ambiguousSegmentCount('earth'), 1);
      expect(ev.confirmedSegmentCount('earth'), 0);
    });

    test('one well-attested part outweighs a whole seen only once', () {
      // A real band name recurs; a one-off collaboration credit does not. So a
      // heavily-used artist beside an unknown name, in a string seen once, is
      // a collaboration.
      final resolver = withCorpus([
        for (var i = 0; i < 12; i++) 'Rigel Theatre',
        'Grand Thaw & Rigel Theatre',
      ]);
      final r = resolver.resolve('Grand Thaw & Rigel Theatre');
      expect(r.outcome, ResolutionOutcome.split);
      expect(r.reason, contains('well attested'));
      expect(r.credits.map((c) => c.creditedAs),
          ['Grand Thaw', 'Rigel Theatre']);
    });

    test('a recurring whole no longer outweighs an attested part', () {
      // Deliberate: the corpus counts one sighting per track, so a twelve-track
      // collaboration album makes its credit look like a "recurring name". That
      // made the recurring-whole rule refuse exactly the album-length
      // collaborations this library is full of, so an attested part now wins.
      final resolver = withCorpus([
        for (var i = 0; i < 6; i++) 'Fire',
        for (var i = 0; i < 4; i++) 'Earth, Wind & Fire',
      ]);
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, ResolutionOutcome.split);
    });

    test('a recurring whole still wins when no part is attested', () {
      // Unchanged, and still the right call: nothing vouches for any part.
      final resolver = withCorpus([
        for (var i = 0; i < 4; i++) 'Earth, Wind & Fire',
      ]);
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, isNot(ResolutionOutcome.split));
    });

    test('distinguishes a comma list from a comma-and-conjunction name', () {
      final resolver = CreditResolver(tokenizer: tokenizer);
      // Three plain comma-separated parts reads as a list.
      expect(
        resolver.resolve('Alice, Bob, Carol').outcome,
        ResolutionOutcome.split,
      );
      // The same shape ending in a conjunction is the classic band-name
      // construction and must not be split on shape alone.
      expect(
        resolver.resolve('Alice, Bob & Carol').outcome,
        ResolutionOutcome.needsReview,
      );
    });
  });

  group('script pairs are one artist, not two', () {
    final resolver = CreditResolver(tokenizer: tokenizer);

    test('a slash between Latin and native script becomes name plus alias', () {
      final r = resolver.resolve('PinocchioP / ピノキオピー');
      expect(r.outcome, ResolutionOutcome.aliasPair);
      expect(r.credits, hasLength(1));
      expect(r.credits.single.creditedAs, 'PinocchioP');
      expect(r.credits.single.aliases, ['ピノキオピー']);
      // Applied, not merely suggested - this is the common case and getting it
      // right is what makes the artist reachable from a Latin keyboard.
      expect(r.isActionable, isTrue);
    });

    test('the known spelling becomes canonical when there is one', () {
      final vocab = MapArtistVocabulary()..add('ピノキオピー', 42);
      final withKnown =
          CreditResolver(tokenizer: tokenizer, vocabulary: vocab);
      final r = withKnown.resolve('PinocchioP / ピノキオピー');
      expect(r.outcome, ResolutionOutcome.aliasPair);
      expect(r.credits.single.artistId, 42);
      expect(r.credits.single.aliases, ['PinocchioP']);
    });

    test('two same-script names on a slash stay a normal split decision', () {
      final r = resolver.resolve('Camellia / Nanahira');
      expect(r.outcome, isNot(ResolutionOutcome.aliasPair));
    });

    test('a cross-script collaboration marker is still a split', () {
      // Only the slash reads as a spelling variant. Everything else is a
      // genuine collaboration, including across scripts.
      for (final raw in const [
        'REOL ✕ ピノキオピー',
        'Giga feat. 初音ミク',
        'Giga、初音ミク',
      ]) {
        expect(resolver.resolve(raw).outcome, ResolutionOutcome.split,
            reason: raw);
      }
    });

    test('detection can be turned off', () {
      final off = CreditResolver(
        tokenizer: tokenizer,
        options: const ResolverOptions(detectAliasPairs: false),
      );
      expect(off.resolve('PinocchioP / ピノキオピー').outcome,
          isNot(ResolutionOutcome.aliasPair));
    });
  });

  group('aggressive splitting option', () {
    test('splits ambiguous separators without corroboration when enabled', () {
      final resolver = CreditResolver(
        tokenizer: tokenizer,
        options: const ResolverOptions(aggressiveSplitting: true),
      );
      final r = resolver.resolve('Earth, Wind & Fire');
      expect(r.outcome, ResolutionOutcome.split);
      expect(r.credits, hasLength(3));
      // Honestly reported as a low-confidence result.
      expect(r.confidence, lessThan(0.7));
    });

    test('an exact artist match still wins over aggressive splitting', () {
      final vocab = MapArtistVocabulary()..add('Earth, Wind & Fire', 7);
      final resolver = CreditResolver(
        tokenizer: tokenizer,
        vocabulary: vocab,
        options: const ResolverOptions(aggressiveSplitting: true),
      );
      expect(
        resolver.resolve('Earth, Wind & Fire').outcome,
        ResolutionOutcome.single,
      );
    });
  });
}

/// A vocabulary that flags names as never-split without holding artist rows
/// for them, so the protection branch can be exercised on its own.
class _ProtectedOnlyVocabulary implements ArtistVocabulary {
  const _ProtectedOnlyVocabulary(this.protectedKeys);

  final Set<String> protectedKeys;

  @override
  List<int> idsForKey(String key) => const [];
  @override
  List<int> idsForCompactKey(String compact) => const [];
  @override
  bool isProtected(String key) => protectedKeys.contains(key);
}
