import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/domain/search/smart_query.dart';

/// The query language smart playlists are written in.
///
/// It is parsed from text someone is still typing, so the rule that matters
/// most is that nothing throws and nothing is silently dropped: a half-typed
/// query should do something reasonable, not nothing.
void main() {
  group('bare words', () {
    test('are collected as terms', () {
      final query = SmartQuery.parse('camellia nanahira');
      expect(query.terms, ['camellia', 'nanahira']);
      expect(query.clauses, isEmpty);
    });

    test('a quoted phrase stays one term', () {
      final query = SmartQuery.parse('"cross separator" hardcore');
      expect(query.terms, ['cross separator', 'hardcore']);
    });

    test('an empty query is empty rather than everything', () {
      expect(SmartQuery.parse('').isEmpty, isTrue);
      expect(SmartQuery.parse('   ').isEmpty, isTrue);
    });
  });

  group('fields', () {
    test('a name field becomes a clause', () {
      final query = SmartQuery.parse('artist:Nanahira');
      expect(query.terms, isEmpty);
      expect(
        query.clauses.single,
        isA<NameClause>()
            .having((c) => c.field, 'field', QueryField.artist)
            .having((c) => c.value, 'value', 'Nanahira')
            .having((c) => c.negated, 'negated', isFalse),
      );
    });

    test('a leading dash negates', () {
      final query = SmartQuery.parse('-tag:remix');
      expect(query.clauses.single.negated, isTrue);
    });

    test('a quoted value keeps its spaces', () {
      final query = SmartQuery.parse('album:"Comic and Cosmic"');
      expect(
        (query.clauses.single as NameClause).value,
        'Comic and Cosmic',
      );
    });

    test('a colon inside a value is not a field separator', () {
      // "AD:HOUSE" is a real album name. Reading "ad" as a field would make a
      // whole shelf unsearchable, and silently: there is no field called ad.
      final query = SmartQuery.parse('AD:HOUSE');
      expect(query.terms, ['AD:HOUSE']);
      expect(query.clauses, isEmpty);
    });

    test('an unknown field stays a word', () {
      final query = SmartQuery.parse('bitrate:320');
      expect(query.terms, ['bitrate:320']);
    });
  });

  group('numbers', () {
    test('a plain number compares for equality', () {
      final clause = SmartQuery.parse('rating:5').clauses.single;
      expect(
        clause,
        isA<NumberClause>()
            .having((c) => c.value, 'value', 5)
            .having((c) => c.comparator, 'comparator', QueryComparator.equal),
      );
    });

    test('comparators are read', () {
      expect(
        (SmartQuery.parse('year:>=2015').clauses.single as NumberClause)
            .comparator,
        QueryComparator.atLeast,
      );
      expect(
        (SmartQuery.parse('plays:>10').clauses.single as NumberClause)
            .comparator,
        QueryComparator.greater,
      );
    });

    test('a range is read as one clause', () {
      final clause = SmartQuery.parse('year:2010-2019').clauses.single
          as NumberClause;
      expect(clause.value, 2010);
      expect(clause.upper, 2019);
    });

    test('a value that is not a number is kept as a word', () {
      // Rather than dropped. Someone typing "year:twenty" should see that
      // something happened with what they typed.
      final query = SmartQuery.parse('year:twenty');
      expect(query.clauses, isEmpty);
      expect(query.terms, ['twenty']);
    });
  });

  group('ages', () {
    test('days, weeks, months and years are all understood', () {
      for (final (text, days) in [
        ('added:<30d', 30),
        ('added:<2w', 14),
        ('added:<3m', 90),
        ('added:<1y', 365),
      ]) {
        final clause = SmartQuery.parse(text).clauses.single as AgeClause;
        expect(clause.age.inDays, days, reason: text);
      }
    });

    test('less-than reads as within, greater-than as older than', () {
      expect(
        (SmartQuery.parse('added:<30d').clauses.single as AgeClause)
            .comparator,
        QueryComparator.less,
      );
      expect(
        SmartQuery.parse('played:>1y').clauses.single.describe(),
        'played over year ago',
      );
    });
  });

  group('describing itself', () {
    test('a whole query reads as a phrase', () {
      expect(
        SmartQuery.parse('artist:Nanahira tag:hardcore -tag:remix added:<30d')
            .describe(),
        'Tracks by Nanahira, tagged hardcore, not tagged remix and added in '
        'the last 30 days',
      );
    });

    test('words are described too', () {
      expect(
        SmartQuery.parse('tag:hardcore camellia').describe(),
        'Tracks tagged hardcore and matching camellia',
      );
    });

    test('a year reads as a date, not as a quantity', () {
      // "released at least 2020" is what treating a year as a number gets you.
      expect(
        SmartQuery.parse('year:>=2020').describe(),
        'Tracks released in 2020 or later',
      );
      expect(
        SmartQuery.parse('year:2010-2019').describe(),
        'Tracks released between 2010 and 2019',
      );
      expect(
        SmartQuery.parse('plays:>10').describe(),
        'Tracks played more than 10 times',
      );
    });

    test('an empty query says so', () {
      expect(SmartQuery.parse('').describe(), 'Every track');
    });
  });
}
