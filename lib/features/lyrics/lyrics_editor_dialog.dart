import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../../domain/lyrics/lyrics_document.dart';
import '../../widgets/time_text.dart';

/// Opens the lyrics editor for [trackId].
///
/// Not dismissible by tapping outside: the only ways out are the header's
/// close button and the system back gesture, both of which go through the
/// same unsaved-changes check either way.
Future<void> showLyricsEditorDialog(
  BuildContext context, {
  required int trackId,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => LyricsEditorDialog(trackId: trackId),
  );
}

/// Where lyrics get written, pasted, linked, and timed against the music.
///
/// A dialog rather than a form section: writing out a whole song and lining
/// its paragraphs up with the music both want room, and both want the rest
/// of the editor out of the way while they happen. See `lyrics_section.dart`
/// for the card that opens this from the track editor.
class LyricsEditorDialog extends ConsumerStatefulWidget {
  const LyricsEditorDialog({super.key, required this.trackId});

  final int trackId;

  @override
  ConsumerState<LyricsEditorDialog> createState() =>
      _LyricsEditorDialogState();
}

class _LyricsEditorDialogState extends ConsumerState<LyricsEditorDialog> {
  final _controller = TextEditingController();
  final _textFocus = FocusNode();

  /// Which document is open for editing. Null is the original.
  String? _language;

  /// What was loaded into the field, so a dirty check is honest.
  String _loaded = '';
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  bool get _dirty => _controller.text.trim() != _loaded.trim();

  /// Puts a document in the field, unless there are unsaved changes in it.
  void _load(LyricsEntry? entry) {
    final text = entry?.raw ?? '';
    if (_dirty) return;
    if (text == _loaded) return;
    _loaded = text;
    _controller.text = text;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => _run(() async {
        await ref.read(lyricsRepositoryProvider).save(
              widget.trackId,
              language: _language,
              content: _controller.text,
            );
        _loaded = _controller.text.trim();
      });

  Future<void> _link() => _run(() async {
        final file = await openFile(
          acceptedTypeGroups: const [
            XTypeGroup(label: 'Lyrics', extensions: ['md', 'lrc', 'txt']),
          ],
        );
        if (file == null) return;
        final ok = await ref.read(lyricsRepositoryProvider).link(
              widget.trackId,
              language: _language,
              path: file.path,
            );
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('That file could not be read.')),
          );
        }
      });

  Future<void> _lookNextToTheFile() => _run(() async {
        final linked = await ref
            .read(lyricsRepositoryProvider)
            .importSidecars(widget.trackId);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              linked == 0
                  ? 'No lyrics file named after the audio file sits next to it.'
                  : 'Linked $linked file${linked == 1 ? '' : 's'}.',
            ),
          ),
        );
      });

  Future<void> _addTranslation() async {
    final code = await showDialog<String>(
      context: context,
      builder: (context) => const _LanguageDialog(),
    );
    if (code == null || !mounted) return;
    setState(() {
      _language = code;
      _loaded = '';
      _controller.clear();
    });
  }

  /// Inserts a `[mm:ss.cc]` stamp at the cursor, then moves the cursor to the
  /// start of the following line so the next line is ready to type straight
  /// after marking when it starts.
  void _insertStamp(Duration at) {
    final text = _controller.text;
    final selection = _controller.selection;
    final cursor = selection.isValid ? selection.start : text.length;
    final stamp = _formatStamp(at);

    final inserted = text.replaceRange(cursor, cursor, stamp);
    final nextLineBreak = inserted.indexOf('\n', cursor + stamp.length);
    final nextCursor =
        nextLineBreak == -1 ? cursor + stamp.length : nextLineBreak + 1;

    _controller.value = TextEditingValue(
      text: inserted,
      selection: TextSelection.collapsed(offset: nextCursor),
    );
    _textFocus.requestFocus();
  }

  Future<void> _requestClose() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final discard = await _confirmDiscard();
    if (discard && mounted) Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard unsaved lyrics?'),
        content: const Text(
          "What's typed here hasn't been saved, and closing now would lose it.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final stored = ref.watch(trackLyricsProvider(widget.trackId)).value;
    final entry = stored?.forLanguage(_language);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = ref.watch(trackRowProvider(widget.trackId)).value;

    // Loading happens in build because the document arrives from a stream,
    // and is guarded by the dirty check so it can never overwrite typing.
    _load(entry);

    final parsed = LyricsDocument.parse(_controller.text);
    final languages = <String?>{
      null,
      ...?stored?.translations.map((t) => t.language),
      _language,
    }.toList();

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        // Reuses _requestClose rather than repeating its confirm-then-pop
        // logic here: this closure captures build's own `context` parameter,
        // which shadows State.context and is what triggers the
        // use_build_context_synchronously lint when awaited across it.
        // _requestClose is declared outside build, so its `context` is
        // unambiguously State.context.
        if (!didPop) _requestClose();
      },
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 60, vertical: 32),
        child: SizedBox(
          width: 760,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        track == null ? 'Lyrics' : 'Lyrics -- ${track.title}',
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_dirty)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          'Unsaved',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.tertiary),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: _requestClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: _MiniPlayer(
                  trackId: widget.trackId,
                  onInsertStamp: _insertStamp,
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (languages.length > 1)
                      SegmentedButton<String?>(
                        showSelectedIcon: false,
                        segments: [
                          for (final code in languages)
                            ButtonSegment(
                              value: code,
                              label: Text(code ?? 'Original'),
                            ),
                        ],
                        selected: {_language},
                        onSelectionChanged: _dirty
                            ? null
                            : (selection) => setState(() {
                                  _language = selection.first;
                                  _loaded = '';
                                  _controller.clear();
                                }),
                      ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _addTranslation,
                      icon: const Icon(Icons.translate, size: 18),
                      label: const Text('Add a translation'),
                    ),
                    if (entry != null)
                      IconButton(
                        tooltip: 'Delete these lyrics',
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                  await ref
                                      .read(lyricsRepositoryProvider)
                                      .remove(widget.trackId,
                                          language: _language);
                                  _loaded = '';
                                  _controller.clear();
                                }),
                        icon: const Icon(Icons.delete_outline),
                      ),
                  ],
                ),
              ),
              if (entry?.isLinked ?? false)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: _LinkedBanner(path: entry!.filePath!, onUnlink: _save),
                ),
              const SizedBox(height: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextField(
                    controller: _controller,
                    focusNode: _textFocus,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    autocorrect: false,
                    style: const TextStyle(fontFamily: 'Consolas', height: 1.5),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: '# Verse 1\n[00:12.30]\nThe first line...',
                      helperText: parsed.isEmpty
                          ? 'Timestamps are optional. Without them the lyrics '
                              'still show, they just do not follow the music.'
                          : '${parsed.sung.length} paragraph'
                              '${parsed.sung.length == 1 ? '' : 's'}'
                              '${parsed.isSynced ? ', timed' : ', untimed'}',
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy || !_dirty ? null : _save,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Save lyrics'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _link,
                      icon: const Icon(Icons.attach_file, size: 18),
                      label: const Text('Link a file'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _lookNextToTheFile,
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      label: const Text('Look next to the file'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Formats a `[mm:ss.cc]` stamp, matching what `LyricsDocument` parses.
String _formatStamp(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds.remainder(60);
  final centiseconds = (d.inMilliseconds.remainder(1000) / 10).floor();
  return '[${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${centiseconds.toString().padLeft(2, '0')}]';
}

/// Play/pause, a seek bar, and a tappable "mark this moment" timestamp.
///
/// Bound to the app's one real player rather than a preview of its own: this
/// is the same transport as the bar at the bottom of the window, condensed
/// to one line. If [trackId] is not what is currently loaded, pressing play
/// replaces the queue with it -- the same thing pressing play anywhere else
/// in the library does -- since there is no way to time lyrics against a
/// song that is not the one playing.
class _MiniPlayer extends ConsumerStatefulWidget {
  const _MiniPlayer({required this.trackId, required this.onInsertStamp});

  final int trackId;
  final void Function(Duration at) onInsertStamp;

  @override
  ConsumerState<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<_MiniPlayer> {
  /// Set while dragging, so the thumb follows the pointer instead of
  /// snapping back to whatever the engine last reported.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final scheme = Theme.of(context).colorScheme;
    final isCurrent = player.current?.trackId == widget.trackId;
    final position =
        isCurrent ? (ref.watch(playbackPositionProvider).value ?? Duration.zero) : Duration.zero;
    final duration = isCurrent ? player.duration : Duration.zero;
    final isPlaying = isCurrent && player.isPlaying;
    final totalMs = duration.inMilliseconds;

    final value = _dragValue ??
        (totalMs == 0 ? 0.0 : (position.inMilliseconds / totalMs).clamp(0.0, 1.0));

    return Row(
      children: [
        IconButton(
          tooltip: isCurrent
              ? (isPlaying ? 'Pause' : 'Play')
              : 'Play this track, to time lyrics against it',
          onPressed: () {
            final controller = ref.read(playerProvider.notifier);
            if (!isCurrent) {
              controller.playTrack(widget.trackId);
            } else {
              controller.togglePlayPause();
            }
          },
          icon: Icon(isCurrent && isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: RoundSliderThumbShape(
                enabledThumbRadius: _dragValue == null ? 0 : 7,
                disabledThumbRadius: 0,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
              activeTrackColor: scheme.primary,
              inactiveTrackColor: scheme.surfaceContainerHighest,
            ),
            child: Slider(
              value: value,
              onChanged: !isCurrent || totalMs == 0
                  ? null
                  : (next) => setState(() => _dragValue = next),
              onChangeEnd: (next) {
                ref.read(playerProvider.notifier).seek(
                      Duration(milliseconds: (next * totalMs).round()),
                    );
                setState(() => _dragValue = null);
              },
            ),
          ),
        ),
        TextButton.icon(
          onPressed: isCurrent ? () => widget.onInsertStamp(position) : null,
          icon: const Icon(Icons.flag_outlined, size: 16),
          label: Text(
            formatDuration(position),
            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
      ],
    );
  }
}

/// Says that a file owns this document, and offers to take it back.
class _LinkedBanner extends StatelessWidget {
  const _LinkedBanner({required this.path, required this.onUnlink});

  final String path;
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.attach_file, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Linked to $path. Edits there win; saving here takes ownership '
              'back and unlinks the file.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a language tag.
class _LanguageDialog extends StatefulWidget {
  const _LanguageDialog();

  @override
  State<_LanguageDialog> createState() => _LanguageDialogState();
}

class _LanguageDialogState extends State<_LanguageDialog> {
  final _controller = TextEditingController();

  /// The ones worth one tap, chosen for this library rather than for the world.
  static const _common = ['en', 'ja', 'fr', 'de', 'es', 'ko', 'zh'];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a translation'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final code in _common)
                ActionChip(
                  label: Text(code),
                  onPressed: () => Navigator.of(context).pop(code),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Or a language tag',
              hintText: 'pt-br',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
