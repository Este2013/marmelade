/// The query language smart playlists are written in.
///
/// Kept deliberately small and legible. A smart playlist is stored as the text
/// someone typed, not as a compiled blob, so the only way it stays editable is
/// if the text is the truth. That rules out anything you could not reasonably
/// retype from memory:
///
///     artist:Nanahira tag=hardcore -tag=remix added:<30d year:>=2015
///
/// Bare words go to the full-text index, which is what makes a smart playlist
/// inherit the thing the whole app is about: a track is indexed under every
/// artist credited on it, so `camellia` finds the collaborations too.
///
/// Anything unparseable is kept as a bare word rather than rejected. A query is
/// typed a character at a time, and refusing to run until it is well-formed
/// would mean showing nothing for most of the typing.
///
/// A name field has three ways to match, chosen by how it's written:
///
///   - `album:XXX` -- contains XXX, the default. Nobody should have to
///     remember the whole name of anything to find it.
///   - `album=XXX` -- exactly XXX, for when "contains" is too loose --
///     `tag=rock` and not every tag that happens to have "rock" in it.
///   - `album:r"XXX"` -- XXX as a regular expression, for the rest.
///
/// `is:` tests a flag rather than a name or number -- `is:Favourite`,
/// `is:Single`. `not:` negates a clause, the same as a leading `-` does,
/// spelled out for when that reads better: `not:tag=remix`. `OR` between
/// clauses is a real alternative, not another word to search for -- see
/// [SmartQuery.parse] for how it splits a query into alternatives.
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
  played('played'),

  /// A flag: `is:Favourite`, `is:Single`. See [QueryFlag].
  flag('is');

  const QueryField(this.keyword);

  final String keyword;

  static QueryField? of(String keyword) =>
      QueryField.values.where((f) => f.keyword == keyword).firstOrNull;

  bool get isName => switch (this) {
        artist || album || title || tag => true,
        _ => false,
      };

  bool get isAge => this == added || this == played;

  bool get isFlag => this == flag;
}

/// How a name field was asked to match.
///
/// [contains] is the default -- write a clause as `field:value` and get
/// substring matching, the way search itself works, so nobody has to type a
/// whole name to find out whether a query works. [exact] (`field=value`) is
/// for when that is too loose: a tag named "rock" should not pull in every
/// tag with "rock" somewhere in it. [regex] (`field:r"..."`) is for
/// everything else, written as a raw string so a backslash means exactly
/// what it looks like.
enum QueryMode { contains, exact, regex }

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

/// A flag `is:` can test.
///
/// Two kinds under one keyword: a plain switch on the track or its album
/// (favourited, verified, lossless...), and a release shape read off the
/// album's own [QueryField] would call `kind` (single, EP, live...). Both
/// read the same way at the call site -- `is:Single` -- because from a
/// listener's chair "what this is" and "whether it has a checkbox ticked"
/// are the same kind of question.
enum QueryFlag {
  favourite('Favourite'),
  rated('Rated'),
  verified('Verified'),
  variousArtists('VariousArtists'),
  lossless('Lossless'),
  missing('Missing'),
  single('Single'),
  ep('EP'),
  live('Live'),
  compilation('Compilation'),
  soundtrack('Soundtrack'),
  demo('Demo'),
  mixtape('Mixtape');

  const QueryFlag(this.keyword);

  final String keyword;

  static QueryFlag? of(String keyword) => QueryFlag.values
      .where((f) => f.keyword.toLowerCase() == keyword.toLowerCase())
      .firstOrNull;
}

/// One condition in a query.
sealed class QueryClause {
  const QueryClause({required this.negated});

  /// Whether the clause was written with a leading `-` or `not:`.
  final bool negated;

  /// Plain English, for the UI. Reads as a phrase, not a sentence.
  String describe();
}

/// A field compared against a name: `artist:Nanahira`, `tag=hardcore`,
/// `album:r"^Vol\.\s*\d+"`.
class NameClause extends QueryClause {
  const NameClause({
    required this.field,
    required this.value,
    this.mode = QueryMode.contains,
    super.negated = false,
  });

  final QueryField field;
  final String value;
  final QueryMode mode;

  @override
  String describe() {
    final subject = switch (field) {
      QueryField.artist => 'by',
      QueryField.album => 'on',
      QueryField.tag => 'tagged',
      QueryField.title => 'called',
      _ => '${field.keyword} is',
    };
    final how = switch (mode) {
      QueryMode.contains => '',
      QueryMode.exact => 'exactly ',
      QueryMode.regex => 'matching ',
    };
    return '${negated ? 'not ' : ''}$subject $how$value';
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

/// A flag test: `is:Favourite`, `-is:Lossless`.
class FlagClause extends QueryClause {
  const FlagClause({required this.flag, super.negated = false});

  final QueryFlag flag;

  @override
  String describe() {
    final not = negated ? 'not ' : '';
    return switch (flag) {
      QueryFlag.favourite => '${not}favourited',
      QueryFlag.rated => negated ? 'unrated' : 'rated',
      QueryFlag.verified => '${not}verified',
      QueryFlag.variousArtists => '${not}on a various-artists release',
      QueryFlag.lossless => '${not}lossless',
      QueryFlag.missing => negated ? 'not missing' : 'missing its file',
      QueryFlag.single ||
      QueryFlag.ep ||
      QueryFlag.live ||
      QueryFlag.compilation ||
      QueryFlag.soundtrack ||
      QueryFlag.demo ||
      QueryFlag.mixtape =>
        '${not}on ${_article(flag.keyword)} ${flag.keyword.toLowerCase()}',
    };
  }

  static String _article(String word) =>
      'AEIOU'.contains(word[0]) ? 'an' : 'a';
}

/// One alternative in a query: everything that must hold together.
///
/// A bare [SmartQuery] is a single group -- every clause and word AND'd, same
/// as before `OR` existed. `OR` splits a query into several of these, any one
/// of which matching is enough; see [SmartQuery.parse].
class QueryGroup {
  const QueryGroup({required this.terms, required this.clauses});

  /// Bare words, to be matched through the search index.
  final List<String> terms;

  final List<QueryClause> clauses;

  bool get isEmpty => terms.isEmpty && clauses.isEmpty;

  /// Parses one group's worth of already-split tokens. Never throws: see the
  /// library comment.
  factory QueryGroup.fromTokens(List<String> tokens) {
    final terms = <String>[];
    final clauses = <QueryClause>[];

    for (final rawToken in tokens) {
      var token = rawToken;
      var negated = false;

      // `not:` is `-` spelled out. Stripped before the usual leading-dash
      // check so `not:-tag=x` is not a thing anyone has to think about --
      // it is simply not recognised as the keyword, and the whole token
      // falls through to being a bare word instead, same as any other
      // unparseable input.
      final lower = token.toLowerCase();
      if (lower.startsWith('not:') && token.length > 4) {
        negated = true;
        token = token.substring(4);
      } else if (token.startsWith('-') && token.length > 1) {
        negated = true;
        token = token.substring(1);
      }

      final split = _splitField(token);
      if (split == null) {
        final word = _unquote(token);
        if (word.isNotEmpty) terms.add(word);
        continue;
      }

      final (field, mode, rawValue) = split;
      if (rawValue.isEmpty) continue;

      final clause = _clauseFor(field, mode, rawValue, negated);
      if (clause != null) {
        clauses.add(clause);
      } else {
        // A field whose value made no sense. Keep the words so the query
        // still does something rather than silently ignoring what was
        // typed.
        final word = _unquote(rawValue);
        if (word.isNotEmpty) terms.add(word);
      }
    }

    return QueryGroup(terms: terms, clauses: clauses);
  }

  /// Finds a leading `field:` or `field=`, and reads a regex value's `r"…"`
  /// wrapper off whichever one it was.
  ///
  /// Checked against every known field rather than by scanning for the
  /// first `:` or `=` in the token: a name can contain either character --
  /// `AD:HOUSE` is an album, not a field named "ad", and the same is true of
  /// `Play=Doe`. Requiring the exact keyword to lead the token is what keeps
  /// those as bare words instead.
  static (QueryField, QueryMode, String)? _splitField(String token) {
    for (final field in QueryField.values) {
      if (token.length > field.keyword.length + 1 &&
          token.substring(0, field.keyword.length).toLowerCase() ==
              field.keyword) {
        final sep = token[field.keyword.length];
        if (sep == ':') {
          final rest = token.substring(field.keyword.length + 1);
          final regex = _regexLiteral(rest);
          if (regex != null) return (field, QueryMode.regex, regex);
          return (field, QueryMode.contains, _unquote(rest));
        }
        if (sep == '=') {
          return (
            field,
            QueryMode.exact,
            _unquote(token.substring(field.keyword.length + 1)),
          );
        }
      }
    }
    return null;
  }

  /// Reads `r"…"` as a raw pattern -- no de-escaping, unlike every other
  /// value -- since a regex's own backslashes are the point of writing one.
  static String? _regexLiteral(String value) {
    if (!value.startsWith('r"') || !value.endsWith('"') || value.length < 3) {
      return null;
    }
    return value.substring(2, value.length - 1);
  }

  static QueryClause? _clauseFor(
    QueryField field,
    QueryMode mode,
    String value,
    bool negated,
  ) {
    if (field.isFlag) {
      final flag = QueryFlag.of(value);
      if (flag == null) return null;
      return FlagClause(flag: flag, negated: negated);
    }

    if (field.isName) {
      return NameClause(field: field, value: value, mode: mode, negated: negated);
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

  static String _unquote(String value) {
    var text = value.trim();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    return text.replaceAll('"', '').trim();
  }

  /// Plain English for this group alone.
  String describe() {
    final parts = [
      for (final clause in clauses) clause.describe(),
      if (terms.isNotEmpty) 'matching ${terms.join(' ')}',
    ];
    if (parts.isEmpty) return '';
    return _joinWithAnd(parts);
  }
}

/// A parsed query: one or more groups, any one of which is enough.
class SmartQuery {
  const SmartQuery({required this.groups});

  final List<QueryGroup> groups;

  bool get isEmpty => groups.every((g) => g.isEmpty);

  /// Every group's own clauses and terms, flattened -- for callers that only
  /// care what fields and words appear anywhere in the query, not how `OR`
  /// arranges them. Suggestions and single-group queries (the common case,
  /// with no `OR` at all) both work this way.
  List<QueryClause> get clauses => [for (final g in groups) ...g.clauses];
  List<String> get terms => [for (final g in groups) ...g.terms];

  /// Parses [text]. Never throws: see the library comment.
  ///
  /// `OR` (uppercase, a token on its own) splits the query into alternative
  /// groups; everything else in a group is AND'd, same as when there was no
  /// `OR` at all. `artist:A OR artist:B tag=live` reads as "by A, or by B and
  /// tagged live" -- `OR` separates groups, it does not reach inside one.
  factory SmartQuery.parse(String text) {
    final tokens = _tokenize(text);
    final groups = <QueryGroup>[];
    var current = <String>[];
    for (final token in tokens) {
      if (token == 'OR') {
        groups.add(QueryGroup.fromTokens(current));
        current = [];
        continue;
      }
      current.add(token);
    }
    groups.add(QueryGroup.fromTokens(current));
    return SmartQuery(groups: groups);
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

  /// Plain English for the whole query, for the playlist page.
  String describe() {
    final parts = [for (final g in groups) g.describe()].where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'Every track';
    if (parts.length == 1) return 'Tracks ${parts.first}';
    return 'Tracks ${parts.join(', or ')}';
  }
}

String _joinWithAnd(List<String> parts) {
  if (parts.length == 1) return parts.first;
  return '${parts.take(parts.length - 1).join(', ')} and ${parts.last}';
}
