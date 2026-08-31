import 'smart_query.dart';

/// The word the caret is in, and where it sits in the text.
///
/// Suggestions replace this and nothing else. Replacing the whole query would
/// throw away the clauses someone already wrote; replacing "the last word"
/// would be wrong the moment they go back to fix something in the middle.
class QueryToken {
  const QueryToken({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;

  bool get isEmpty => text.isEmpty;

  /// The `-` that negates a clause, kept when a suggestion is applied so
  /// `-tag:` does not silently become `tag:`.
  bool get isNegated => text.startsWith('-');

  /// The token without its leading dash.
  String get body => isNegated ? text.substring(1) : text;
}

/// What should be offered where the caret is.
enum SuggestionKind {
  /// Nothing typed yet in this word: offer the fields.
  fields,

  /// A partial field name: offer the fields that match.
  matchingFields,

  /// A field and a colon: offer names for it.
  names,

  /// A field that takes a number: offer comparators.
  comparators,

  /// A field that takes an age: offer spans.
  ages,

  /// A bare word, which searches everything. Nothing to suggest.
  none,
}

/// What to suggest, and for what.
class SuggestionRequest {
  const SuggestionRequest({
    required this.kind,
    required this.token,
    this.field,
    this.partial = '',
  });

  final SuggestionKind kind;
  final QueryToken token;

  /// The field whose values are wanted, when [kind] needs one.
  final QueryField? field;

  /// What has been typed of the value so far.
  final String partial;
}

/// Reads the token at [caret] out of [text].
///
/// Words are separated by spaces, and a quoted run counts as one word so that
/// `album:"Comic and` is still being typed rather than three tokens.
QueryToken tokenAt(String text, int caret) {
  final at = caret.clamp(0, text.length);

  // Scanned forward from the start rather than backwards from the caret.
  // Whether a space is inside quotes depends on every quote before it, and
  // walking backwards can only see the ones it has already passed -- which put
  // the caret in the middle of `album:"Comic and Cosmic"` in the wrong word.
  var start = 0;
  var inQuotes = false;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == '"') inQuotes = !inQuotes;
    if (char != ' ' || inQuotes) continue;

    if (i >= at) {
      return QueryToken(start: start, end: i, text: text.substring(start, i));
    }
    start = i + 1;
  }

  return QueryToken(
    start: start,
    end: text.length,
    text: text.substring(start),
  );
}

/// Works out what to offer at [caret].
SuggestionRequest suggestionAt(String text, int caret) {
  final token = tokenAt(text, caret);
  final body = token.body;

  final colon = body.indexOf(':');
  if (colon < 0) {
    return SuggestionRequest(
      kind: body.isEmpty ? SuggestionKind.fields : SuggestionKind.matchingFields,
      token: token,
      partial: body,
    );
  }

  final field = QueryField.of(body.substring(0, colon).toLowerCase());
  if (field == null) {
    // Not a field, so this is a bare word that happens to contain a colon --
    // "AD:HOUSE" is an album, not a field named ad.
    return SuggestionRequest(
      kind: SuggestionKind.none,
      token: token,
      partial: body,
    );
  }

  final value = body.substring(colon + 1);
  return SuggestionRequest(
    kind: switch (field) {
      _ when field.isName => SuggestionKind.names,
      _ when field.isAge => SuggestionKind.ages,
      _ => SuggestionKind.comparators,
    },
    token: token,
    field: field,
    partial: value,
  );
}

/// One thing that can be offered.
class Suggestion {
  const Suggestion({
    required this.insert,
    required this.label,
    this.detail,
    this.continues = false,
  });

  /// The text this puts in place of the token.
  final String insert;

  final String label;

  /// A second line: what a field means, how many tracks a tag has.
  final String? detail;

  /// True when accepting it leaves the caret in the same word, because more is
  /// expected -- picking `artist:` means a name comes next.
  final bool continues;
}

/// The fields, with a word about each.
///
/// Described rather than just listed: a query language is only usable if the
/// thing offering it also says what the options mean.
const fieldSuggestions = <({QueryField field, String detail})>[
  (field: QueryField.artist, detail: 'Anyone credited on the track'),
  (field: QueryField.album, detail: 'The release it is on'),
  (field: QueryField.title, detail: "The track's own title"),
  (field: QueryField.tag, detail: 'A tag, including inherited ones'),
  (field: QueryField.releaseYear, detail: 'Year, or a range'),
  (field: QueryField.rating, detail: 'Stars, 1 to 5'),
  (field: QueryField.playCount, detail: 'How many times played'),
  (field: QueryField.added, detail: 'How long ago it was added'),
  (field: QueryField.played, detail: 'How long ago it was played'),
];

/// The spans offered for an age field.
const ageSuggestions = <({String value, String label})>[
  (value: '<7d', label: 'in the last week'),
  (value: '<30d', label: 'in the last month'),
  (value: '<3m', label: 'in the last 3 months'),
  (value: '<1y', label: 'in the last year'),
  (value: '>1y', label: 'over a year ago'),
];

/// The comparators offered for a number field.
const comparatorSuggestions = <({String value, String label})>[
  (value: '>=', label: 'at least'),
  (value: '<=', label: 'at most'),
  (value: '>', label: 'more than'),
  (value: '<', label: 'less than'),
];

/// The field suggestions matching what has been typed.
List<Suggestion> suggestFields(String partial) {
  final typed = partial.toLowerCase();
  return [
    for (final entry in fieldSuggestions)
      if (entry.field.keyword.startsWith(typed))
        Suggestion(
          insert: '${entry.field.keyword}:',
          label: '${entry.field.keyword}:',
          detail: entry.detail,
          // A field alone matches nothing; the value is the point.
          continues: true,
        ),
  ];
}

/// Replaces [token] in [text] with [insert], and says where the caret goes.
///
/// A space is added after a completed suggestion so the next word can be typed
/// straight away, and withheld after one that expects more in the same word.
({String text, int caret}) applySuggestion(
  String text,
  QueryToken token,
  Suggestion suggestion,
) {
  final prefix = token.isNegated ? '-' : '';
  final replacement =
      '$prefix${suggestion.insert}${suggestion.continues ? '' : ' '}';
  final next = text.replaceRange(token.start, token.end, replacement);
  return (text: next, caret: token.start + replacement.length);
}

/// Wraps a value in quotes when it needs them.
///
/// A name with a space in it is one value, and without quotes the parser would
/// read the rest of it as separate search words -- `artist:Earth, Wind` would
/// look for artists called "Earth," and then anything matching "Wind".
String quoteIfNeeded(String value) =>
    value.contains(' ') ? '"$value"' : value;
