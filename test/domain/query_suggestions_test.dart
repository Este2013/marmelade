import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/domain/search/query_suggestions.dart';
import 'package:marmelade/domain/search/smart_query.dart';

/// What the query box offers, and where.
///
/// The query language is small but nobody can be expected to know it, so these
/// suggestions are the only thing that makes it usable. The rule they must
/// never break: a suggestion replaces the word the caret is in and nothing
/// else, because the rest of the query is work someone already did.
void main() {
  group('finding the word the caret is in', () {
    test('the empty end of a query is an empty token', () {
      final token = tokenAt('tag:hardcore ', 13);
      expect(token.text, '');
      expect(token.start, 13);
    });

    test('the middle of a word is that word', () {
      final token = tokenAt('artist:camellia tag:x', 10);
      expect(token.text, 'artist:camellia');
      expect(token.start, 0);
      expect(token.end, 15);
    });

    test('a word in the middle of a query, not the last one', () {
      // Going back to fix something earlier must not rewrite the end.
      final token = tokenAt('tag:hardcore artist:x year:2020', 16);
      expect(token.text, 'artist:x');
    });

    test('a quoted value with a space is one word', () {
      final token = tokenAt('album:"Comic and Cosmic"', 20);
      expect(token.text, 'album:"Comic and Cosmic"');
    });

    test('a caret past the end is clamped', () {
      expect(tokenAt('tag:x', 99).text, 'tag:x');
    });
  });

  group('what to offer', () {
    test('an empty word offers the fields', () {
      final request = suggestionAt('', 0);
      expect(request.kind, SuggestionKind.fields);
      expect(suggestFields(request.partial).map((s) => s.insert),
          contains('artist:'));
    });

    test('after a space, the fields again', () {
      final request = suggestionAt('tag:hardcore ', 13);
      expect(request.kind, SuggestionKind.fields);
    });

    test('a partial field name narrows the fields', () {
      final request = suggestionAt('art', 3);
      expect(request.kind, SuggestionKind.matchingFields);
      expect(
        suggestFields(request.partial).map((s) => s.insert),
        ['artist:'],
      );
    });

    test('a name field asks for names', () {
      final request = suggestionAt('artist:cam', 10);
      expect(request.kind, SuggestionKind.names);
      expect(request.field, QueryField.artist);
      expect(request.partial, 'cam');
    });

    test('a number field offers comparators', () {
      final request = suggestionAt('year:', 5);
      expect(request.kind, SuggestionKind.comparators);
      expect(request.field, QueryField.releaseYear);
    });

    test('an age field offers spans', () {
      final request = suggestionAt('added:', 6);
      expect(request.kind, SuggestionKind.ages);
      expect(ageSuggestions.map((a) => a.value), contains('<30d'));
    });

    test('a bare word with a colon is not a field', () {
      // "AD:HOUSE" is an album. Offering to complete a field named "ad" would
      // be confidently wrong.
      final request = suggestionAt('AD:HOUSE', 8);
      expect(request.kind, SuggestionKind.none);
    });

    test('a negated clause is still recognised', () {
      final request = suggestionAt('-tag:rem', 8);
      expect(request.kind, SuggestionKind.names);
      expect(request.field, QueryField.tag);
      expect(request.partial, 'rem');
      expect(request.token.isNegated, isTrue);
    });
  });

  group('applying one', () {
    test('replaces only the word the caret is in', () {
      const text = 'tag:hardcore art year:2020';
      final request = suggestionAt(text, 16);
      final applied = applySuggestion(
        text,
        request.token,
        suggestFields(request.partial).first,
      );

      expect(applied.text, 'tag:hardcore artist: year:2020');
      // The caret lands after the colon, ready for the name.
      expect(applied.caret, 'tag:hardcore artist:'.length);
    });

    test('a field keeps the caret in the word, a value moves past it', () {
      final field = suggestFields('art').first;
      expect(field.continues, isTrue);

      final applied = applySuggestion(
        'art',
        tokenAt('art', 3),
        const Suggestion(insert: 'camellia', label: 'Camellia'),
      );
      // A completed value gets a space, so the next word can be typed at once.
      expect(applied.text, 'camellia ');
      expect(applied.caret, 9);
    });

    test('a negation survives', () {
      const text = '-tag';
      final request = suggestionAt(text, 4);
      final applied = applySuggestion(
        text,
        request.token,
        suggestFields(request.partial).first,
      );
      expect(applied.text, '-tag:');
    });
  });

  group('quoting', () {
    test('a name with a space is quoted', () {
      // Otherwise the parser reads the rest as separate search words.
      expect(quoteIfNeeded('Earth Wind'), '"Earth Wind"');
      expect(quoteIfNeeded('Camellia'), 'Camellia');
    });

    test('a quoted suggestion parses back to one clause', () {
      final query = SmartQuery.parse('artist:${quoteIfNeeded('Earth Wind')}');
      expect(query.terms, isEmpty);
      expect((query.clauses.single as NameClause).value, 'Earth Wind');
    });
  });
}
