/// Text folding used for every kind of name matching in the library.
///
/// Dart has no ICU, so the folds here are hand-written. They cover what a real
/// music collection actually throws at a matcher: full-width Latin from
/// Japanese tag editors, accents typed inconsistently, hiragana where katakana
/// was meant, and punctuation that varies between releases of the same album.
library;

/// Characters treated as decoration rather than content.
///
/// Brackets are folded to spaces rather than dropped, so `"A (feat. B)"`
/// becomes `"A feat. B"` and stays tokenizable, instead of collapsing into a
/// single meaningless word.
const _punctuation = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

/// Accented Latin letters grouped under the plain letter they fold to.
///
/// Deliberately not exhaustive: it covers Latin-1 Supplement and Latin
/// Extended-A, which is where Western and Central European artist names live.
/// Both cases are listed because the fold runs before lower-casing.
///
/// Grouped by target rather than kept as two parallel strings, so the table
/// cannot silently fall out of alignment.
const _accentFolds = <String, String>{
  'a': 'àáâãäåāăąÀÁÂÃÄÅĀĂĄ',
  'c': 'çćĉċčÇĆĈĊČ',
  'd': 'ďđĎĐ',
  'e': 'èéêëēĕėęěÈÉÊËĒĔĖĘĚ',
  'g': 'ĝğġģĜĞĠĢ',
  'h': 'ĥħĤĦ',
  'i': 'ìíîïĩīĭįıÌÍÎÏĨĪĬĮİ',
  'j': 'ĵĴ',
  'k': 'ķĶ',
  'l': 'ĺļľłĹĻĽŁ',
  'n': 'ñńņňÑŃŅŇ',
  'o': 'òóôõöøōŏőÒÓÔÕÖØŌŎŐ',
  'r': 'ŕŗřŔŖŘ',
  's': 'śŝşšŚŜŞŠ',
  't': 'ţťŧŢŤŦ',
  'u': 'ùúûüũūŭůűųÙÚÛÜŨŪŬŮŰŲ',
  'w': 'ŵŴ',
  'y': 'ýÿŷÝŸŶ',
  'z': 'źżžŹŻŽ',
  // Ligatures and letters that expand to two characters.
  'ae': 'æÆ',
  'oe': 'œŒ',
  'th': 'ðþÐÞ',
  'ss': 'ß',
};

final Map<int, String> _accentMap = {
  for (final entry in _accentFolds.entries)
    for (final rune in entry.value.runes) rune: entry.key,
};

/// Folds a string into its canonical matching form.
///
/// The result is lower-case, accent-free, punctuation-free, with runs of
/// whitespace collapsed to a single space. It is a *key*, never shown to the
/// user.
///
/// ```
/// normalizeKey('Björk')            == 'bjork'
/// normalizeKey('AC/DC')            == 'ac dc'
/// normalizeKey('ＲＥＯＬ')          == 'reol'
/// normalizeKey('ぴのきおぴー')       == 'ピノキオピー'
/// ```
///
/// Punctuation folds to a space rather than vanishing, which keeps word
/// boundaries meaningful; see [compactKey] for the variant that removes them.
String normalizeKey(String input) {
  if (input.isEmpty) return '';
  final out = StringBuffer();
  var pendingSpace = false;

  for (final rune in input.runes) {
    final folded = _foldRune(rune);
    if (folded == null) {
      // Anything unmapped and non-alphanumeric acts as a break.
      pendingSpace = out.isNotEmpty;
      continue;
    }
    if (folded == ' ') {
      pendingSpace = out.isNotEmpty;
      continue;
    }
    if (pendingSpace) {
      out.write(' ');
      pendingSpace = false;
    }
    out.write(folded);
  }
  return out.toString();
}

/// Like [normalizeKey] but with all spaces removed.
///
/// Used as a second-chance match, so `"AC/DC"`, `"AC DC"` and `"ACDC"` all
/// collapse to `acdc` and find each other. Looser than [normalizeKey], so it
/// is only consulted after an exact key match fails.
String compactKey(String input) => normalizeKey(input).replaceAll(' ', '');

/// Folds a single rune, or returns null if it carries no meaning for matching.
///
/// Returns `' '` for characters that should act as a word break.
String? _foldRune(int rune) {
  // Full-width ASCII (U+FF01-U+FF5E) maps onto its ASCII twin.
  if (rune >= 0xFF01 && rune <= 0xFF5E) {
    rune = rune - 0xFEE0;
  }
  // Ideographic and other exotic spaces.
  if (rune == 0x3000 || rune == 0x00A0 || rune == 0x200B) return ' ';

  // Hiragana folds onto katakana so ぴのきおぴー matches ピノキオピー. U+3097
  // and U+3098 are unassigned, and the marks above U+3098 are not letters.
  if (rune >= 0x3041 && rune <= 0x3096) {
    return String.fromCharCode(rune + 0x60);
  }

  if (rune < 0x80) {
    final ch = String.fromCharCode(rune);
    if (_punctuation.contains(ch)) return ' ';
    if (rune <= 0x20) return ' ';
    return ch.toLowerCase();
  }

  final accent = _accentMap[rune];
  if (accent != null) return accent;

  final ch = String.fromCharCode(rune);
  // Unicode punctuation, symbols and separators break words; everything else
  // (CJK, Cyrillic, Greek, Hangul, ...) is content and is kept lower-cased.
  if (_isBreaking(rune)) return ' ';
  return ch.toLowerCase();
}

/// Whether a non-ASCII rune should be treated as a word break.
bool _isBreaking(int rune) {
  // General punctuation, CJK symbols/punctuation, full-width forms,
  // arrows, math operators, dingbats and box drawing.
  return (rune >= 0x2000 && rune <= 0x206F) || // general punctuation
      (rune >= 0x2190 && rune <= 0x2BFF) || // arrows, math, misc symbols
      (rune >= 0x3001 && rune <= 0x303F) || // CJK symbols and punctuation
      (rune >= 0xFE30 && rune <= 0xFE4F) || // CJK compatibility forms
      (rune >= 0xFF5F && rune <= 0xFF65) || // halfwidth/fullwidth punctuation
      (rune >= 0x00A1 && rune <= 0x00BF) || // Latin-1 punctuation and symbols
      rune == 0x00D7 || // multiplication sign
      rune == 0x00F7; // division sign
}

/// Produces a sortable form of a display name.
///
/// Moves a leading English article to the end, so "The Beatles" files under B.
/// Only applied when the caller has no explicit sort name to use.
String sortKeyFor(String name) {
  final key = normalizeKey(name);
  for (final article in const ['the ', 'a ', 'an ']) {
    if (key.startsWith(article)) {
      return '${key.substring(article.length)} ${article.trim()}';
    }
  }
  return key;
}

/// Whether [text] contains any CJK ideograph, kana or Hangul.
///
/// Used to decide when a romanised alias would be worth prompting for, and
/// when to lean on the trigram search index rather than token search.
bool containsCjk(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x3040 && rune <= 0x30FF) || // kana
        (rune >= 0x3400 && rune <= 0x4DBF) || // CJK ext A
        (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK unified
        (rune >= 0xAC00 && rune <= 0xD7AF) || // Hangul syllables
        (rune >= 0xF900 && rune <= 0xFAFF)) {
      return true;
    }
  }
  return false;
}
