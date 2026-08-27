/// Lyrics: markdown, with timestamps where the words should move.
///
/// One format for three things people actually have. A plain block of text
/// pasted from anywhere. An LRC file, where every line carries its own
/// timestamp. And the format this app is for: markdown, where a timestamp on
/// its own line starts a new paragraph, so a song scrolls a verse at a time
/// instead of a word at a time.
///
///     # Verse 1
///     [00:12.30]
///     The first paragraph, which
///     runs across two lines.
///
///     [00:24.10]
///     The second paragraph.
///
///     > A note about the song. Never sung, never highlighted.
///
/// Markdown is deliberately a subset -- headings, emphasis, notes, paragraphs.
/// Lyrics are not documents; they are short, structured text with the
/// occasional aside, and every construct beyond this list would be one more
/// thing that renders differently from what someone typed.
///
/// Nothing here throws. Lyrics arrive from files written by strangers and from
/// a field someone is still typing in, so a malformed timestamp becomes text
/// rather than an error.
library;

/// A run of text with the emphasis it was written with.
class LyricsSpan {
  const LyricsSpan(this.text, {this.bold = false, this.italic = false});

  final String text;
  final bool bold;
  final bool italic;

  @override
  bool operator ==(Object other) =>
      other is LyricsSpan &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic;

  @override
  int get hashCode => Object.hash(text, bold, italic);

  @override
  String toString() =>
      'LyricsSpan("$text"${bold ? ' bold' : ''}${italic ? ' italic' : ''})';
}

/// One line of lyrics.
class LyricsLine {
  const LyricsLine({required this.spans, this.at});

  final List<LyricsSpan> spans;

  /// When this line is sung, for LRC-style documents where every line is timed.
  final Duration? at;

  String get text => spans.map((s) => s.text).join();

  bool get isEmpty => text.trim().isEmpty;
}

/// A paragraph: the unit that gets highlighted and scrolled to.
class LyricsBlock {
  const LyricsBlock({
    required this.lines,
    this.at,
    this.heading,
    this.isNote = false,
  });

  final List<LyricsLine> lines;

  /// When this paragraph starts. Null in an unsynced document.
  final Duration? at;

  /// A section label written as `# Chorus` above the paragraph.
  final String? heading;

  /// Written as a `>` blockquote: an aside, not words to sing.
  final bool isNote;

  String get text => lines.map((l) => l.text).join('\n');
}

/// A parsed lyrics document.
class LyricsDocument {
  const LyricsDocument({
    required this.blocks,
    required this.offset,
    this.language,
  });

  final List<LyricsBlock> blocks;

  /// The document's own timing offset, from an LRC `[offset:]` tag.
  ///
  /// Separate from the offset stored per track: this one came with the file and
  /// belongs to it, while the stored one is the correction someone made here.
  final Duration offset;

  /// BCP-47 tag, when the document knows what language it is in.
  final String? language;

  static const empty = LyricsDocument(blocks: [], offset: Duration.zero);

  bool get isEmpty => blocks.every((b) => b.text.trim().isEmpty);

  /// Whether anything in it is timed, which is what lets it follow playback.
  bool get isSynced => blocks.any((b) => b.at != null) ||
      blocks.any((b) => b.lines.any((l) => l.at != null));

  /// Sung lines only, with notes left out.
  Iterable<LyricsBlock> get sung => blocks.where((b) => !b.isNote);

  /// The paragraph being sung at [position], or null before the first one.
  ///
  /// [extraOffset] is the correction stored against the track, added to the
  /// document's own. Positive means the words come later.
  int? activeBlock(Duration position, {Duration extraOffset = Duration.zero}) {
    final at = position - offset - extraOffset;
    int? active;
    for (var i = 0; i < blocks.length; i++) {
      final start = blocks[i].at;
      if (start == null) continue;
      if (start <= at) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  /// Parses [text]. See the library comment: this never throws.
  factory LyricsDocument.parse(String text, {String? language}) {
    final blocks = <LyricsBlock>[];
    var offset = Duration.zero;

    // Pending state for the paragraph being read.
    var lines = <LyricsLine>[];
    Duration? blockAt;
    String? heading;
    var isNote = false;

    /// Emits a heading that never got a paragraph, so it is not simply lost.
    void emitLoneHeading() {
      if (heading == null) return;
      blocks.add(LyricsBlock(lines: const [], at: blockAt, heading: heading));
      heading = null;
      blockAt = null;
    }

    // [last] distinguishes the end of the document from the end of a
    // paragraph. A pending heading has to survive the flush that a timestamp
    // line triggers -- "# Chorus" then "[01:00]" then the words is one block,
    // and emitting the heading at the timestamp would split it in two.
    void flush({bool last = false}) {
      if (lines.isEmpty) {
        if (last) emitLoneHeading();
        return;
      }
      blocks.add(LyricsBlock(
        lines: lines,
        at: blockAt ?? lines.firstWhere((l) => l.at != null,
            orElse: () => const LyricsLine(spans: [])).at,
        heading: heading,
        isNote: isNote,
      ));
      lines = <LyricsLine>[];
      blockAt = null;
      heading = null;
      isNote = false;
    }

    for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trimRight();
      final trimmed = line.trim();

      // A blank line ends the paragraph.
      if (trimmed.isEmpty) {
        flush();
        continue;
      }

      // An LRC metadata tag. Only the offset means anything to a reader; the
      // rest duplicates what the catalog already knows better.
      final meta = _metaTag.firstMatch(trimmed);
      if (meta != null) {
        if (meta.group(1)!.toLowerCase() == 'offset') {
          final ms = int.tryParse(meta.group(2)!.trim().replaceAll('+', ''));
          if (ms != null) offset = Duration(milliseconds: ms);
        }
        continue;
      }

      // A heading starts a new paragraph and labels it.
      final headingMatch = _heading.firstMatch(trimmed);
      if (headingMatch != null) {
        flush();
        // Two headings in a row: the first one labelled nothing, but it was
        // still written.
        emitLoneHeading();
        heading = headingMatch.group(1)!.trim();
        continue;
      }

      final stamps = _leadingStamps(trimmed);
      final rest = trimmed.substring(stamps.consumed).trim();

      // Timestamps alone on a line: this is where the next paragraph starts.
      if (stamps.times.isNotEmpty && rest.isEmpty) {
        flush();
        blockAt = stamps.times.first;
        continue;
      }

      // A note. Kept out of the sung text so it is never highlighted.
      if (rest.startsWith('>')) {
        if (!isNote) flush();
        isNote = true;
        lines.add(LyricsLine(
          spans: _spans(rest.substring(1).trim()),
          at: stamps.times.firstOrNull,
        ));
        continue;
      }
      if (isNote) flush();

      // An LRC line: timestamped text. A line carrying several timestamps is a
      // repeated chorus, and is emitted once per timestamp so it appears every
      // time it is sung rather than only the first.
      if (stamps.times.length > 1) {
        flush();
        for (final time in stamps.times) {
          blocks.add(LyricsBlock(
            lines: [LyricsLine(spans: _spans(rest), at: time)],
            at: time,
          ));
        }
        continue;
      }

      lines.add(LyricsLine(spans: _spans(rest), at: stamps.times.firstOrNull));
    }
    flush(last: true);

    // LRC documents are one line per timestamp, and grouping them into
    // paragraphs would guess at structure the file does not have. They come out
    // as one block per line, which is what a timed line is.
    final split = _splitPerLineIfEveryLineIsTimed(blocks);

    split.sort((a, b) {
      final left = a.at, right = b.at;
      if (left == null || right == null) return 0;
      return left.compareTo(right);
    });

    return LyricsDocument(
      blocks: split,
      offset: offset,
      language: language,
    );
  }

  /// Splits paragraphs whose every line carries its own timestamp.
  static List<LyricsBlock> _splitPerLineIfEveryLineIsTimed(
    List<LyricsBlock> blocks,
  ) {
    final result = <LyricsBlock>[];
    for (final block in blocks) {
      final timed = block.lines.where((l) => l.at != null).length;
      if (block.lines.length > 1 && timed == block.lines.length) {
        for (final line in block.lines) {
          result.add(LyricsBlock(
            lines: [line],
            at: line.at,
            heading: line == block.lines.first ? block.heading : null,
            isNote: block.isNote,
          ));
        }
        continue;
      }
      result.add(block);
    }
    return result;
  }

  /// Reads the run of `[mm:ss.cc]` stamps at the start of a line.
  static ({List<Duration> times, int consumed}) _leadingStamps(String line) {
    final times = <Duration>[];
    var index = 0;
    while (index < line.length) {
      final match = _stamp.matchAsPrefix(line, index);
      if (match == null) break;
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      final fraction = match.group(3);
      var ms = 0;
      if (fraction != null && fraction.isNotEmpty) {
        // Two digits are centiseconds, three are milliseconds. Both appear in
        // the wild, and reading one as the other is off by 10x.
        final digits = fraction.padRight(3, '0').substring(0, 3);
        ms = int.parse(digits);
      }
      times.add(Duration(minutes: minutes, seconds: seconds, milliseconds: ms));
      index = match.end;
    }
    return (times: times, consumed: index);
  }

  /// Splits text into emphasis runs.
  ///
  /// `**bold**`, `*italic*`, `_italic_`. Unclosed markers stay as text, because
  /// a line being typed is unclosed for as long as it takes to type it.
  static List<LyricsSpan> _spans(String text) {
    if (text.isEmpty) return const [];
    final spans = <LyricsSpan>[];
    final buffer = StringBuffer();
    var bold = false;
    var italic = false;

    void push() {
      if (buffer.isEmpty) return;
      spans.add(LyricsSpan(buffer.toString(), bold: bold, italic: italic));
      buffer.clear();
    }

    var i = 0;
    while (i < text.length) {
      final char = text[i];
      if (char != '*' && char != '_') {
        buffer.write(char);
        i += 1;
        continue;
      }

      // A run of markers is one delimiter, not several. Reading it character
      // by character turns an unmatched `**` into two single markers around
      // nothing, which silently eats the asterisks someone typed.
      var run = 0;
      while (i + run < text.length && text[i + run] == char) {
        run += 1;
      }

      final marker = run >= 2 ? '**' : char;
      final width = run >= 2 ? 2 : 1;
      final isBold = width == 2;
      // A triple run and up is not bold-and-italic here: emphasis in lyrics is
      // one or the other, and a run nobody can close is just text.
      final usable = run <= 2 && (isBold ? char == '*' : true);
      final open = isBold ? bold : italic;
      final matches = usable &&
          (open ? _closesAt(text, i) : _opensAt(text, i, marker));

      if (!matches) {
        buffer.write(text.substring(i, i + run));
        i += run;
        continue;
      }

      push();
      if (isBold) {
        bold = !bold;
      } else {
        italic = !italic;
      }
      i += width;
    }
    push();
    return spans;
  }

  /// Whether a marker at [i] opens emphasis.
  ///
  /// Markdown's flanking rule, and the reason for it: `2 * 3` is arithmetic,
  /// not italics. A marker opens only when something non-blank follows it and
  /// a real closer exists later on the line.
  static bool _opensAt(String text, int i, String marker) {
    final after = i + marker.length;
    if (after >= text.length) return false;
    if (_isBlank(text[after])) return false;
    return _hasCloser(text, after, marker);
  }

  /// Whether a marker at [i] closes emphasis: it must follow something.
  static bool _closesAt(String text, int i) =>
      i > 0 && !_isBlank(text[i - 1]);

  static bool _hasCloser(String text, int from, String marker) {
    var i = from;
    while (true) {
      final at = text.indexOf(marker, i);
      if (at < 0) return false;
      if (_closesAt(text, at)) return true;
      i = at + marker.length;
    }
  }

  static bool _isBlank(String char) => char.trim().isEmpty;

  static final _stamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final _metaTag = RegExp(r'^\[([a-zA-Z]{2,10}):([^\]]*)\]$');
  static final _heading = RegExp(r'^#{1,6}\s+(.*)$');
}

/// Two documents shown together: the words, and what they mean.
///
/// Aligned by timestamp when both are timed, and by position when they are not.
/// A translation is written line for line with its original often enough that
/// position is a good default, and timestamps are exact when they exist.
class LyricsAlignment {
  const LyricsAlignment(this.pairs);

  final List<({LyricsBlock original, LyricsBlock? translated})> pairs;

  factory LyricsAlignment.of(
    LyricsDocument original,
    LyricsDocument? translation,
  ) {
    final blocks = original.blocks;
    if (translation == null || translation.isEmpty) {
      return LyricsAlignment([
        for (final block in blocks) (original: block, translated: null),
      ]);
    }

    final other = translation.blocks;
    if (original.isSynced && translation.isSynced) {
      return LyricsAlignment([
        for (final block in blocks)
          (
            original: block,
            translated: block.at == null ? null : _nearest(other, block.at!),
          ),
      ]);
    }

    return LyricsAlignment([
      for (var i = 0; i < blocks.length; i++)
        (
          original: blocks[i],
          translated: i < other.length ? other[i] : null,
        ),
    ]);
  }

  /// The block whose timestamp is closest to [at], within half a second.
  ///
  /// Bounded, because a translation missing a verse should leave that verse
  /// untranslated rather than pairing it with whatever is nearest.
  static LyricsBlock? _nearest(List<LyricsBlock> blocks, Duration at) {
    LyricsBlock? best;
    var bestDelta = const Duration(milliseconds: 500);
    for (final block in blocks) {
      final other = block.at;
      if (other == null) continue;
      final delta = (other - at).abs();
      if (delta <= bestDelta) {
        best = block;
        bestDelta = delta;
      }
    }
    return best;
  }
}
