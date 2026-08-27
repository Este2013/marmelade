import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/domain/lyrics/lyrics_document.dart';

/// The lyrics format: markdown, with timestamps where the words should move.
///
/// Two sources feed this and neither is trustworthy. Files written by strangers
/// carry every LRC variant ever shipped, and the editor feeds it text that is
/// half-typed by definition. So most of these tests are about what happens to
/// input nobody designed.
void main() {
  group('paragraphs', () {
    test('a timestamp on its own line starts a paragraph', () {
      final doc = LyricsDocument.parse('''
[00:12.30]
The first paragraph, which
runs across two lines.

[00:24.10]
The second paragraph.
''');

      expect(doc.blocks, hasLength(2));
      expect(doc.blocks.first.at, const Duration(seconds: 12, milliseconds: 300));
      expect(
        doc.blocks.first.text,
        'The first paragraph, which\nruns across two lines.',
      );
      expect(doc.blocks.last.at, const Duration(seconds: 24, milliseconds: 100));
      expect(doc.isSynced, isTrue);
    });

    test('a blank line ends a paragraph even without timestamps', () {
      final doc = LyricsDocument.parse('One\ntwo\n\nthree');
      expect(doc.blocks, hasLength(2));
      expect(doc.isSynced, isFalse);
    });

    test('a heading labels the paragraph under it', () {
      final doc = LyricsDocument.parse('# Chorus\n[01:00]\nSing along');
      expect(doc.blocks.single.heading, 'Chorus');
      expect(doc.blocks.single.text, 'Sing along');
    });

    test('a note is kept out of the sung text', () {
      final doc = LyricsDocument.parse(
        '[00:05]\nWords\n\n> Recorded in one take.',
      );
      expect(doc.blocks, hasLength(2));
      expect(doc.blocks.last.isNote, isTrue);
      expect(doc.blocks.last.text, 'Recorded in one take.');
      expect(doc.sung.map((b) => b.text), ['Words']);
    });
  });

  group('emphasis', () {
    test('bold and italics are read', () {
      final doc = LyricsDocument.parse('**loud** and *soft* and _also soft_');
      final spans = doc.blocks.single.lines.single.spans;
      expect(
        spans.where((s) => s.bold).map((s) => s.text),
        ['loud'],
      );
      expect(
        spans.where((s) => s.italic).map((s) => s.text),
        ['soft', 'also soft'],
      );
    });

    test('an unclosed marker stays text', () {
      // Which is every marker, for as long as it takes to type the closing one.
      final doc = LyricsDocument.parse('2 * 3 and **half typed');
      expect(doc.blocks.single.lines.single.text, '2 * 3 and **half typed');
    });
  });

  group('LRC files', () {
    test('every line timed becomes one paragraph per line', () {
      // Grouping these into paragraphs would invent structure the file does
      // not have.
      final doc = LyricsDocument.parse('''
[00:01.00]First line
[00:05.50]Second line
[00:09.25]Third line
''');
      expect(doc.blocks, hasLength(3));
      expect(doc.blocks[1].at, const Duration(seconds: 5, milliseconds: 500));
      expect(doc.blocks[1].text, 'Second line');
    });

    test('two digits are centiseconds, three are milliseconds', () {
      // Both ship in the wild, and reading one as the other is off by ten.
      final doc = LyricsDocument.parse('[00:01.5]a\n[00:02.05]b\n[00:03.500]c');
      expect(doc.blocks[0].at, const Duration(seconds: 1, milliseconds: 500));
      expect(doc.blocks[1].at, const Duration(seconds: 2, milliseconds: 50));
      expect(doc.blocks[2].at, const Duration(seconds: 3, milliseconds: 500));
    });

    test('a repeated chorus appears at every one of its timestamps', () {
      final doc = LyricsDocument.parse('[00:30][01:30][02:30]The chorus');
      expect(doc.blocks, hasLength(3));
      expect(doc.blocks.map((b) => b.text).toSet(), {'The chorus'});
      expect(doc.blocks.last.at, const Duration(minutes: 2, seconds: 30));
    });

    test('the offset tag is honoured and the rest ignored', () {
      final doc = LyricsDocument.parse('''
[ar:Some Artist]
[ti:Some Title]
[offset:+500]
[00:10.00]Words
''');
      expect(doc.offset, const Duration(milliseconds: 500));
      // The metadata lines are not lyrics.
      expect(doc.blocks.single.text, 'Words');
    });

    test('blocks come out in time order however the file was written', () {
      final doc = LyricsDocument.parse('[00:20]late\n[00:10]early');
      expect(doc.blocks.map((b) => b.text), ['early', 'late']);
    });
  });

  group('following playback', () {
    final doc = LyricsDocument.parse(
      '[00:10]\nfirst\n\n[00:20]\nsecond\n\n[00:30]\nthird',
    );

    test('nothing is active before the first paragraph', () {
      expect(doc.activeBlock(const Duration(seconds: 5)), isNull);
    });

    test('the paragraph whose time has come is active', () {
      expect(doc.activeBlock(const Duration(seconds: 10)), 0);
      expect(doc.activeBlock(const Duration(seconds: 19)), 0);
      expect(doc.activeBlock(const Duration(seconds: 20)), 1);
      expect(doc.activeBlock(const Duration(minutes: 5)), 2);
    });

    test('the stored correction shifts what is active', () {
      // Positive means the words come later, so at 20s the first is still up.
      expect(
        doc.activeBlock(
          const Duration(seconds: 20),
          extraOffset: const Duration(seconds: 2),
        ),
        0,
      );
    });
  });

  group('nothing throws', () {
    test('every prefix of a document parses', () {
      const source = '# V1\n[00:12.30]\n**Words** here\n\n> note\n[bad:\n[01:';
      for (var i = 0; i <= source.length; i++) {
        expect(
          () => LyricsDocument.parse(source.substring(0, i)),
          returnsNormally,
          reason: 'prefix of length $i',
        );
      }
    });

    test('empty and whitespace are empty, not broken', () {
      expect(LyricsDocument.parse('').isEmpty, isTrue);
      expect(LyricsDocument.parse('   \n\n  ').isEmpty, isTrue);
    });

    test('a malformed timestamp is just text', () {
      final doc = LyricsDocument.parse('[99:99:99:99]what');
      expect(doc.blocks.single.text, contains('what'));
    });
  });

  group('translations', () {
    test('timed documents align by timestamp', () {
      final original = LyricsDocument.parse('[00:10]\n星\n\n[00:20]\n月');
      final translated = LyricsDocument.parse(
        '[00:20]\nmoon\n\n[00:10]\nstar',
        language: 'en',
      );

      final aligned = LyricsAlignment.of(original, translated);
      expect(aligned.pairs.first.original.text, '星');
      expect(aligned.pairs.first.translated?.text, 'star');
      expect(aligned.pairs.last.translated?.text, 'moon');
    });

    test('untimed documents align by position', () {
      final original = LyricsDocument.parse('one\n\ntwo');
      final translated = LyricsDocument.parse('un\n\ndeux', language: 'fr');

      final aligned = LyricsAlignment.of(original, translated);
      expect(
        aligned.pairs.map((p) => p.translated?.text),
        ['un', 'deux'],
      );
    });

    test('a verse the translation skipped stays untranslated', () {
      // Rather than pairing with whatever timestamp happens to be nearest.
      final original = LyricsDocument.parse('[00:10]\na\n\n[01:00]\nb');
      final translated = LyricsDocument.parse('[00:10]\nA', language: 'en');

      final aligned = LyricsAlignment.of(original, translated);
      expect(aligned.pairs.first.translated?.text, 'A');
      expect(aligned.pairs.last.translated, isNull);
    });

    test('no translation still pairs every line', () {
      final original = LyricsDocument.parse('one\n\ntwo');
      final aligned = LyricsAlignment.of(original, null);
      expect(aligned.pairs, hasLength(2));
      expect(aligned.pairs.every((p) => p.translated == null), isTrue);
    });
  });
}
