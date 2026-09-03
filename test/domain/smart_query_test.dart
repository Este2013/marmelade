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

  group('modes', () {
    test('a colon is contains by default', () {
      final clause = SmartQuery.parse('album:Cosmic').clauses.single
          as NameClause;
      expect(clause.mode, QueryMode.contains);
      expect(clause.value, 'Cosmic');
    });

    test('an equals sign is exact', () {
      final clause = SmartQuery.parse('tag=rock').clauses.single
          as NameClause;
      expect(clause.mode, QueryMode.exact);
      expect(clause.value, 'rock');
    });

    test('a quoted exact value keeps its spaces', () {
      final clause = SmartQuery.parse('album="Comic and Cosmic"')
          .clauses
          .single as NameClause;
      expect(clause.mode, QueryMode.exact);
      expect(clause.value, 'Comic and Cosmic');
    });

    test('r"..." after a colon is a regex, unescaped', () {
      final clause = SmartQuery.parse(r'album:r"^Vol\.\s*\d+"').clauses.single
          as NameClause;
      expect(clause.mode, QueryMode.regex);
      expect(clause.value, r'^Vol\.\s*\d+');
    });

    test('a regex with a space in it stays one token', () {
      final clause = SmartQuery.parse(r'title:r"^(Intro|Outro) \d+"')
          .clauses
          .single as NameClause;
      expect(clause.value, r'^(Intro|Outro) \d+');
    });

    test('r"..." is only special after a colon, not after equals', () {
      // No regex mode for `=` -- the field is named "field=r"pattern"" the
      // same as any other exact literal, quotes and all kept out.
      final clause = SmartQuery.parse('tag=r"literal"').clauses.single
          as NameClause;
      expect(clause.mode, QueryMode.exact);
      expect(clause.value, 'r"literal"'.replaceAll('"', ''));
    });

    test('an equals sign in a value does not become a field separator', () {
      // Same protection as the colon case: a real value can contain the
      // character being used elsewhere as a separator.
      final query = SmartQuery.parse('Play=Doe');
      expect(query.terms, ['Play=Doe']);
      expect(query.clauses, isEmpty);
    });
  });

  group('is:', () {
    test('a known flag becomes a clause', () {
      final clause = SmartQuery.parse('is:Favourite').clauses.single
          as FlagClause;
      expect(clause.flag, QueryFlag.favourite);
      expect(clause.negated, isFalse);
    });

    test('flags are matched case-insensitively', () {
      expect(
        (SmartQuery.parse('is:single').clauses.single as FlagClause).flag,
        QueryFlag.single,
      );
      expect(
        (SmartQuery.parse('is:EP').clauses.single as FlagClause).flag,
        QueryFlag.ep,
      );
    });

    test('an unknown flag stays a word', () {
      final query = SmartQuery.parse('is:Purple');
      expect(query.clauses, isEmpty);
      expect(query.terms, ['Purple']);
    });

    test('a leading dash negates a flag the same as any other clause', () {
      final clause = SmartQuery.parse('-is:Lossless').clauses.single
          as FlagClause;
      expect(clause.flag, QueryFlag.lossless);
      expect(clause.negated, isTrue);
    });
  });

  group('not:', () {
    test('negates the clause the same as a leading dash', () {
      final clause = SmartQuery.parse('not:tag=remix').clauses.single;
      expect(clause.negated, isTrue);
      expect((clause as NameClause).mode, QueryMode.exact);
      expect(clause.value, 'remix');
    });

    test('negates a flag', () {
      final clause = SmartQuery.parse('not:is:Favourite').clauses.single
          as FlagClause;
      expect(clause.negated, isTrue);
      expect(clause.flag, QueryFlag.favourite);
    });

    test('is spelled exactly "not:" -- a field named not stays a word', () {
      final query = SmartQuery.parse('notes:something');
      expect(query.terms, ['notes:something']);
    });
  });

  group('OR', () {
    test('splits a query into alternative groups', () {
      final query = SmartQuery.parse('artist:Nanahira OR artist:Camellia');
      expect(query.groups, hasLength(2));
      expect(
        (query.groups[0].clauses.single as NameClause).value,
        'Nanahira',
      );
      expect(
        (query.groups[1].clauses.single as NameClause).value,
        'Camellia',
      );
    });

    test('everything else in a group stays AND\'d', () {
      final query =
          SmartQuery.parse('artist:A tag=live OR artist:B tag=remix');
      expect(query.groups, hasLength(2));
      expect(query.groups[0].clauses, hasLength(2));
      expect(query.groups[1].clauses, hasLength(2));
    });

    test('a lowercase "or" is just a word, not the keyword', () {
      final query = SmartQuery.parse('cake or pie');
      expect(query.groups, hasLength(1));
      expect(query.groups.single.terms, ['cake', 'or', 'pie']);
    });

    test('a query with no OR at all is a single group', () {
      final query = SmartQuery.parse('artist:Nanahira tag=hardcore');
      expect(query.groups, hasLength(1));
      // And its flattened terms/clauses read exactly as before OR existed.
      expect(query.clauses, hasLength(2));
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
