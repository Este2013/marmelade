import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../../domain/lyrics/lyrics_document.dart';
import 'edit_widgets.dart';

/// Where lyrics get written, pasted, or linked.
///
/// Three ways in, because people have lyrics in three states: typed here,
/// pasted from a page, or already sitting in a file they would rather keep
/// editing in a real editor. The third is why linking exists at all, and why
/// the file stays the source of truth when it is used.
class LyricsSection extends ConsumerStatefulWidget {
  const LyricsSection({super.key, required this.trackId});

  final int trackId;

  @override
  ConsumerState<LyricsSection> createState() => _LyricsSectionState();
}

class _LyricsSectionState extends ConsumerState<LyricsSection> {
  final _controller = TextEditingController();

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
            XTypeGroup(
              label: 'Lyrics',
              extensions: ['md', 'lrc', 'txt'],
            ),
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

  @override
  Widget build(BuildContext context) {
    final stored = ref.watch(trackLyricsProvider(widget.trackId)).value;
    final entry = stored?.forLanguage(_language);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Loading happens in build because the document arrives from a stream, and
    // is guarded by the dirty check so it can never overwrite typing.
    _load(entry);

    final parsed = LyricsDocument.parse(_controller.text);
    final languages = <String?>{
      null,
      ...?stored?.translations.map((t) => t.language),
      _language,
    }.toList();

    return EditSection(
      title: 'Lyrics',
      subtitle: 'Markdown, with a timestamp on its own line where a new '
          'paragraph starts. A file can be linked instead, and then the file '
          'stays the source of truth.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
              if (languages.length > 1) const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _addTranslation,
                icon: const Icon(Icons.translate, size: 18),
                label: const Text('Add a translation'),
              ),
              const Spacer(),
              if (entry != null)
                IconButton(
                  tooltip: 'Delete these lyrics',
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                            await ref.read(lyricsRepositoryProvider).remove(
                                  widget.trackId,
                                  language: _language,
                                );
                            _loaded = '';
                            _controller.clear();
                          }),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (entry?.isLinked ?? false)
            _LinkedBanner(
              path: entry!.filePath!,
              onUnlink: () => _save(),
            ),
          TextField(
            controller: _controller,
            minLines: 8,
            maxLines: 20,
            autocorrect: false,
            style: const TextStyle(fontFamily: 'Consolas', height: 1.5),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: '# Verse 1\n[00:12.30]\nThe first line...',
              helperText: parsed.isEmpty
                  ? 'Timestamps are optional. Without them the lyrics still '
                      'show, they just do not follow the music.'
                  : '${parsed.sung.length} paragraph'
                      '${parsed.sung.length == 1 ? '' : 's'}'
                      '${parsed.isSynced ? ', timed' : ', untimed'}',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy || !_dirty ? null : _save,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _link,
                icon: const Icon(Icons.attach_file, size: 18),
                label: const Text('Link a file'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _lookNextToTheFile,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('Look next to the audio'),
              ),
              const Spacer(),
              if (_dirty)
                Text(
                  'Unsaved',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.tertiary),
                ),
            ],
          ),
        ],
      ),
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
      margin: const EdgeInsets.only(bottom: 12),
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
          onPressed: () =>
              Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
