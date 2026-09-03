import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../../domain/lyrics/lyrics_document.dart';
import '../../widgets/empty_state.dart';
import '../lyrics/lyrics_editor_dialog.dart';

/// Extensions a dropped or picked file must have to be worth trying as
/// lyrics.
const _lyricsExtensions = ['md', 'lrc', 'txt'];

/// The words, following the music.
///
/// A paragraph at a time rather than a line at a time: that is what the format
/// is for, and a verse of context reads better than one highlighted line with
/// nothing around it. An unsynced document is simply not highlighted -- it
/// still scrolls, and pretending to know where the singer is would be worse
/// than admitting the file does not say.
class LyricsPane extends ConsumerStatefulWidget {
  const LyricsPane({super.key});

  @override
  ConsumerState<LyricsPane> createState() => _LyricsPaneState();
}

class _LyricsPaneState extends ConsumerState<LyricsPane> {
  final _scroll = ScrollController();
  final _blockKeys = <int, GlobalKey>{};
  int? _lastActive;

  /// The track whose linked files have already been checked for edits.
  int? _checkedTrack;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the sung paragraph into view, a little above centre.
  ///
  /// Above centre rather than centred, because what comes next matters more
  /// than what just went by.
  void _follow(int? active) {
    if (active == null || active == _lastActive) return;
    _lastActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _blockKeys[active];
      final context = key?.currentContext;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.32,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// Re-reads any linked document whose file has changed since it was stored.
  Future<void> _refresh(TrackLyrics? stored) async {
    if (stored == null || !mounted) return;
    final repository = ref.read(lyricsRepositoryProvider);
    for (final entry in stored.all.where((e) => e.isLinked)) {
      await repository.refreshIfStale(entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(playerProvider.select((s) => s.current));
    if (track == null) {
      return const EmptyState(
        icon: Icons.lyrics_outlined,
        title: 'Nothing playing',
        message: 'Lyrics show up here for whatever is on.',
      );
    }

    final lyrics = ref.watch(trackLyricsProvider(track.trackId));
    final stored = lyrics.value;
    final language = ref.watch(lyricsLanguageProvider);
    final bilingual = ref.watch(lyricsBilingualProvider);

    if (lyrics.isLoading && stored == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (stored == null || stored.isEmpty) {
      return _NoLyrics(trackId: track.trackId);
    }

    // A translation on its own is a valid way to read; a translation beside the
    // original is the better default when there is one.
    final chosen = stored.forLanguage(language) ?? stored.all.first;
    final original = stored.original ?? chosen;
    final showBoth = bilingual &&
        chosen.language != null &&
        original.language != chosen.language;

    final alignment = LyricsAlignment.of(
      showBoth ? original.document : chosen.document,
      showBoth ? chosen.document : null,
    );

    final active = ref.watch(activeLyricsBlockProvider((
      trackId: track.trackId,
      language: showBoth ? original.language : chosen.language,
    )));
    _follow(active);

    // A linked file is the source of truth, so check whether it moved on
    // without us -- once per track, not per frame, and after the frame so a
    // write cannot happen during a build.
    if (_checkedTrack != track.trackId) {
      _checkedTrack = track.trackId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(stored));
    }

    return Column(
      children: [
        _Toolbar(lyrics: stored, entry: chosen),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 120),
            itemCount: alignment.pairs.length,
            itemBuilder: (context, index) {
              final pair = alignment.pairs[index];
              return _Paragraph(
                key: _blockKeys.putIfAbsent(index, GlobalKey.new),
                block: pair.original,
                translated: pair.translated,
                isActive: index == active,
                // Nothing is highlighted in an unsynced document, so nothing
                // should be dimmed either.
                isDimmed: active != null && index != active,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Language choice and the timing nudge.
class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.lyrics, required this.entry});

  final TrackLyrics lyrics;
  final LyricsEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final repository = ref.read(lyricsRepositoryProvider);
    final synced = entry.document.isSynced;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 12, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Edit lyrics',
            onPressed: () =>
                showLyricsEditorDialog(context, trackId: entry.trackId),
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
          const SizedBox(width: 4),
          if (lyrics.all.length > 1)
            SizedBox(
              height: 34,
              child: SegmentedButton<String?>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  for (final one in lyrics.all)
                    ButtonSegment(value: one.language, label: Text(one.label)),
                ],
                selected: {entry.language},
                onSelectionChanged: (selection) => ref
                    .read(lyricsLanguageProvider.notifier)
                    .set(selection.first),
              ),
            ),
          if (entry.language != null) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: ref.watch(lyricsBilingualProvider)
                  ? 'Show the translation on its own'
                  : 'Show the original alongside',
              isSelected: ref.watch(lyricsBilingualProvider),
              onPressed: () =>
                  ref.read(lyricsBilingualProvider.notifier).toggle(),
              icon: const Icon(Icons.vertical_split_outlined, size: 18),
            ),
          ],
          const Spacer(),
          if (synced) ...[
            // The nudge, because a timed file is usually right to within a
            // second and wrong by exactly that second.
            Text(
              entry.offset == Duration.zero
                  ? 'In time'
                  : '${entry.offset.isNegative ? '' : '+'}'
                      '${(entry.offset.inMilliseconds / 1000).toStringAsFixed(1)}s',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            IconButton(
              tooltip: 'The words come earlier',
              onPressed: () => repository.setOffset(
                entry.id,
                entry.offset - const Duration(milliseconds: 200),
              ),
              icon: const Icon(Icons.remove, size: 18),
            ),
            IconButton(
              tooltip: 'The words come later',
              onPressed: () => repository.setOffset(
                entry.id,
                entry.offset + const Duration(milliseconds: 200),
              ),
              icon: const Icon(Icons.add, size: 18),
            ),
          ] else
            Tooltip(
              message: 'No timestamps in this document, so it cannot follow '
                  'the music. Add [mm:ss] lines to sync it.',
              child: Icon(
                Icons.schedule_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// One paragraph, with its translation under it when there is one.
class _Paragraph extends StatelessWidget {
  const _Paragraph({
    super.key,
    required this.block,
    required this.isActive,
    required this.isDimmed,
    this.translated,
  });

  final LyricsBlock block;
  final LyricsBlock? translated;
  final bool isActive;
  final bool isDimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (block.isNote) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: scheme.outlineVariant, width: 3),
            ),
          ),
          child: Text(
            block.text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    final colour = isActive ? scheme.onSurface : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (block.heading != null) ...[
            Text(
              block.heading!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.primary.withValues(alpha: isDimmed ? 0.6 : 1),
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 8),
          ],
          // Opacity, not size. Animating the text *style* between two font
          // sizes re-lays out the paragraph on every frame of the transition
          // and moves every semantics rectangle with it: measured at three
          // times the accessibility-bridge errors, on the same bridge that a
          // zero-area node once crashed outright. Opacity animates a render
          // object and leaves layout alone.
          AnimatedOpacity(
            opacity: isDimmed ? 0.45 : 1,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
            // Never dropped from the tree at zero: adding and removing a node
            // per transition is exactly the churn being avoided here.
            alwaysIncludeSemantics: true,
            child: DefaultTextStyle(
              style: theme.textTheme.titleLarge!
                  .copyWith(color: colour, height: 1.45),
              child: Text.rich(
                TextSpan(
                  children: [
                    for (var i = 0; i < block.lines.length; i++) ...[
                      if (i > 0) const TextSpan(text: '\n'),
                      for (final span in block.lines[i].spans)
                        TextSpan(
                          text: span.text,
                          style: TextStyle(
                            fontWeight: span.bold ? FontWeight.w700 : null,
                            fontStyle: span.italic ? FontStyle.italic : null,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (translated != null && translated!.text.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              translated!.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant
                    .withValues(alpha: isDimmed ? 0.5 : 0.9),
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What to do when a track has no lyrics yet.
class _NoLyrics extends ConsumerStatefulWidget {
  const _NoLyrics({required this.trackId});

  final int trackId;

  @override
  ConsumerState<_NoLyrics> createState() => _NoLyricsState();
}

class _NoLyricsState extends ConsumerState<_NoLyrics> {
  var _looking = false;
  var _linking = false;
  var _dragging = false;
  int? _found;
  String? _error;

  bool get _busy => _looking || _linking;

  Future<void> _look() async {
    setState(() {
      _looking = true;
      _error = null;
    });
    final linked =
        await ref.read(lyricsRepositoryProvider).importSidecars(widget.trackId);
    if (!mounted) return;
    setState(() {
      _looking = false;
      _found = linked;
    });
  }

  Future<void> _pickFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Lyrics', extensions: _lyricsExtensions),
      ],
    );
    if (file == null || !mounted) return;
    await _linkPath(file.path);
  }

  /// Shared by the file picker and a file dropped from the OS.
  Future<void> _linkPath(String path) async {
    setState(() {
      _linking = true;
      _error = null;
    });
    final ok = await ref
        .read(lyricsRepositoryProvider)
        .link(widget.trackId, path: path);
    if (!mounted) return;
    setState(() {
      _linking = false;
      if (!ok) _error = 'That file could not be read.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        if (_busy || details.files.isEmpty) return;
        // The first file with a supported extension, not just the first
        // file: dropping a folder's worth of things next to the audio
        // shouldn't require picking the lyrics one out by hand first.
        final path = details.files
            .map((f) => f.path)
            .where((p) => _lyricsExtensions
                .any((ext) => p.toLowerCase().endsWith('.$ext')))
            .firstOrNull;
        if (path == null) {
          setState(() => _error =
              'That is not a .lrc, .md or .txt file.');
          return;
        }
        _linkPath(path);
      },
      child: DecoratedBox(
        // Only paints while something is actually being dragged over it --
        // otherwise this would just be a permanent, pointless outline around
        // an empty state that already reads as empty.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: _dragging
              ? Border.all(color: scheme.primary, width: 2)
              : Border.all(color: Colors.transparent, width: 2),
          color: _dragging ? scheme.primary.withValues(alpha: 0.06) : null,
        ),
        child: EmptyState(
          icon: _dragging ? Icons.file_download_outlined : Icons.lyrics_outlined,
          title: _dragging ? 'Drop it here' : 'No lyrics for this track',
          message: _dragging
              ? 'A .lrc, .md or .txt file, linked and kept in sync with '
                  'wherever it lives.'
              : _error ??
                  (_found == 0
                      ? 'No .lrc, .md or .txt file named after the audio '
                          'file sits next to it. Drag one in, link one, or '
                          'write them in the track editor.'
                      : 'Write or paste them in the track editor, or link a '
                          'file and keep editing it wherever you like.'),
          action: Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _look,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: Text(_looking ? 'Looking...' : 'Look next to the file'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.attach_file, size: 18),
                label: Text(_linking ? 'Linking...' : 'Link a file'),
              ),
              FilledButton.icon(
                onPressed: () =>
                    showLyricsEditorDialog(context, trackId: widget.trackId),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Write them'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
