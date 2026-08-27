/// The query language smart playlists are written in.
///
/// Kept deliberately small and legible. A smart playlist is stored as the text
/// someone typed, not as a compiled blob, so the only way it stays editable is
/// if the text is the truth. That rules out anything you could not reasonably
/// retype from memory:
///
///     artist:Nanahira tag:hardcore -tag:remix added:<30d year:>=2015
///
/// Bare words go to the full-text index, which is what makes a smart playlist
/// inherit the thing the whole app is about: a track is indexed under every
/// artist credited on it, so `camellia` finds the collaborations too.
///
/// Anything unparseable is kept as a bare word rather than rejected. A query is
/// typed a character at a time, and refusing to run until it is well-formed
/// would mean showing nothing for most of the typing.
library;

/// A field a clause can test.
enum QueryField {
  /// Any artist credited on the track, in any role.
  artist('artist'),

  album('album'),

  /// The track's own title.
  title('title'),

  /// A tag on the track, including one inherited from its album or a playlist.
  tag('tag'),

  releaseYear('year'),
  rating('rating'),
  playCount('plays'),

  /// How long ago the track was added to the library.
  added('added'),

  /// How long ago it was last played. Never played matches nothing.
  played('played');

  const QueryField(this.keyword);

  final String keyword;

  static QueryField? of(String keyword) =>
      QueryField.values.where((f) => f.keyword == keyword).firstOrNull;

  bool get isName => switch (this) {
        artist || album || title || tag => true,
        _ => false,
      };

  bool get isAge => this == added || this == played;
}

/// How a numeric or age clause compares.
enum QueryComparator {
  equal(''),
  atLeast('>='),
  atMost('<='),
  greater('>'),
  less('<');

  const QueryComparator(this.symbol);

  final String symbol;
}

/// One condition in a query.
sealed class QueryClause {
  const QueryClause({required this.negated});

  /// Whether the clause was written with a leading `-`.
  final bool negated;

  /// Plain English, for the UI. Reads as a phrase, not a sentence.
  String describe();
}

/// A field compared against a name: `artist:Nanahira`, `-tag:remix`.
///
/// Matched as a prefix, for the same reason search matches prefixes: you should
/// not have to finish typing a name to see whether it works.
class NameClause extends QueryClause {
  const NameClause({
    required this.field,
    required this.value,
    super.negated = false,
  });

  final QueryField field;
  final String value;

  @override
  String describe() {
    final subject = switch (field) {
      QueryField.artist => 'by',
      QueryField.album => 'on',
      QueryField.tag => 'tagged',
      QueryField.title => 'called',
      _ => '${field.keyword} is',
    };
    return '${negated ? 'not ' : ''}$subject $value';
  }
}

/// A field compared against a number: `year:>=2015`, `rating:5`.
class NumberClause extends QueryClause {
  const NumberClause({
    required this.field,
    required this.comparator,
    required this.value,
    this.upper,
    super.negated = false,
  });

  final QueryField field;
  final QueryComparator comparator;
  final int value;

  /// Set for a range, written `year:2010-2019`.
  final int? upper;

  @override
  String describe() {
    final not = negated ? 'not ' : '';

    // A year is a point in time and a count is a quantity, so they do not read
    // the same way: "released at least 2020" is what you get from treating a
    // year as a number.
    if (field == QueryField.releaseYear) {
      if (upper != null) return '${not}released between $value and $upper';
      return not +
          switch (comparator) {
            QueryComparator.equal => 'released in $value',
            QueryComparator.atLeast => 'released in $value or later',
            QueryComparator.atMost => 'released in $value or earlier',
            QueryComparator.greater => 'released after $value',
            QueryComparator.less => 'released before $value',
          };
    }

    final name = field == QueryField.rating ? 'rated' : 'played';
    final times = field == QueryField.playCount ? ' times' : '';
    if (upper != null) return '$not$name between $value and $upper$times';
    final how = switch (comparator) {
      QueryComparator.equal => '',
      QueryComparator.atLeast => 'at least ',
      QueryComparator.atMost => 'at most ',
      QueryComparator.greater => 'more than ',
      QueryComparator.less => 'fewer than ',
    };
    return '$not$name $how$value$times';
  }
}

/// A field compared against an age: `added:<30d`, `played:>1y`.
///
/// `<` reads as "within": `added:<30d` is everything added in the last thirty
/// days, which is what someone typing it means, even though the literal
/// comparison on the stored timestamp runs the other way.
class AgeClause extends QueryClause {
  const AgeClause({
    required this.field,
    required this.comparator,
    required this.amount,
    required this.unit,
    super.negated = false,
  });

  final QueryField field;
  final QueryComparator comparator;

  /// How many [unit]s, as written.
  final int amount;

  /// One of `d`, `w`, `m`, `y`, kept so the description can echo what was
  /// typed. Deriving it back from a duration turned `30d` into "a month",
  /// which is close enough to be right and different enough to be annoying.
  final String unit;

  /// The span, with months and years as fixed lengths. A smart playlist is a
  /// filter, not a calendar: "the last 3 months" does not need February.
  Duration get age => switch (unit) {
        'd' => Duration(days: amount),
        'w' => Duration(days: amount * 7),
        'm' => Duration(days: amount * 30),
        _ => Duration(days: amount * 365),
      };

  @override
  String describe() {
    final verb = field == QueryField.added ? 'added' : 'played';
    final noun = switch (unit) {
      'd' => 'day',
      'w' => 'week',
      'm' => 'month',
      _ => 'year',
    };
    final span = amount == 1 ? noun : '$amount ${noun}s';
    final not = negated ? 'not ' : '';
    return switch (comparator) {
      QueryComparator.greater ||
      QueryComparator.atLeast =>
        '$not$verb over $span ago',
      _ => '$not$verb in the last $span',
    };
  }
}

/// A parsed query: words for the index, and clauses for the catalog.
class SmartQuery {
  const SmartQuery({required this.terms, required this.clauses});

  /// Bare words, to be matched through the search index.
  final List<String> terms;

  final List<QueryClause> clauses;

  bool get isEmpty => terms.isEmpty && clauses.isEmpty;

  /// Parses [text]. Never throws: see the library comment.
  factory SmartQuery.parse(String text) {
    final terms = <String>[];
    final clauses = <QueryClause>[];

    for (final token in _tokenize(text)) {
      var body = token;
      var negated = false;
      if (body.startsWith('-') && body.length > 1) {
        negated = true;
        body = body.substring(1);
      }

      final colon = body.indexOf(':');
      // A colon is only a field separator when what precedes it is a field.
      // Album titles contain colons -- "AD:HOUSE" -- and treating that as a
      // field named "ad" would make a whole shelf unsearchable.
      final field =
          colon <= 0 ? null : QueryField.of(body.substring(0, colon).toLowerCase());
      if (field == null) {
        final word = _unquote(body);
        if (word.isNotEmpty) terms.add(word);
        continue;
      }

      final value = _unquote(body.substring(colon + 1));
      if (value.isEmpty) continue;

      final clause = _clauseFor(field, value, negated);
      if (clause != null) {
        clauses.add(clause);
      } else {
        // A field whose value made no sense. Keep the words so the query still
        // does something rather than silently ignoring what was typed.
        terms.add(value);
      }
    }

    return SmartQuery(terms: terms, clauses: clauses);
  }

  static QueryClause? _clauseFor(QueryField field, String value, bool negated) {
    if (field.isName) {
      return NameClause(field: field, value: value, negated: negated);
    }

    final (comparator, rest) = _comparator(value);

    if (field.isAge) {
      final span = _span(rest);
      if (span == null) return null;
      return AgeClause(
        field: field,
        comparator: comparator,
        amount: span.amount,
        unit: span.unit,
        negated: negated,
      );
    }

    // A range, which only makes sense without a comparator.
    final range = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(rest);
    if (range != null && comparator == QueryComparator.equal) {
      return NumberClause(
        field: field,
        comparator: QueryComparator.equal,
        value: int.parse(range.group(1)!),
        upper: int.parse(range.group(2)!),
        negated: negated,
      );
    }

    final number = int.tryParse(rest);
    if (number == null) return null;
    return NumberClause(
      field: field,
      comparator: comparator,
      value: number,
      negated: negated,
    );
  }

  static (QueryComparator, String) _comparator(String value) {
    for (final comparator in [
      QueryComparator.atLeast,
      QueryComparator.atMost,
      QueryComparator.greater,
      QueryComparator.less,
    ]) {
      if (value.startsWith(comparator.symbol)) {
        return (comparator, value.substring(comparator.symbol.length).trim());
      }
    }
    return (QueryComparator.equal, value.trim());
  }

  static ({int amount, String unit})? _span(String value) {
    final match = RegExp(r'^(\d+)\s*([dwmy])$').firstMatch(value.toLowerCase());
    if (match == null) return null;
    return (amount: int.parse(match.group(1)!), unit: match.group(2)!);
  }

  /// Splits on whitespace, keeping quoted runs together.
  static List<String> _tokenize(String text) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var quoted = false;

    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      if (char == '"') {
        quoted = !quoted;
        buffer.write(char);
        continue;
      }
      if (!quoted && char.trim().isEmpty) {
        if (buffer.isNotEmpty) tokens.add(buffer.toString());
        buffer.clear();
        continue;
      }
      buffer.write(char);
    }
    if (buffer.isNotEmpty) tokens.add(buffer.toString());
    return tokens;
  }

  static String _unquote(String value) {
    var text = value.trim();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    return text.replaceAll('"', '').trim();
  }

  /// Plain English for the whole query, for the playlist page.
  String describe() {
    final parts = [
      for (final clause in clauses) clause.describe(),
      if (terms.isNotEmpty) 'matching ${terms.join(' ')}',
    ];
    if (parts.isEmpty) return 'Every track';
    return 'Tracks ${_joinWithAnd(parts)}';
  }
}

String _joinWithAnd(List<String> parts) {
  if (parts.length == 1) return parts.first;
  return '${parts.take(parts.length - 1).join(', ')} and ${parts.last}';
}
