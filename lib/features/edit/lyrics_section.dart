import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../lyrics/lyrics_editor_dialog.dart';
import 'edit_widgets.dart';

/// Where lyrics stand for this track, with a way in to change them.
///
/// The actual writing, pasting and linking happens in
/// [LyricsEditorDialog] now, not here -- a text area worth spending real
/// time in wants more room than one card in a long form has to give it.
class LyricsSection extends ConsumerWidget {
  const LyricsSection({super.key, required this.trackId});

  final int trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final stored = ref.watch(trackLyricsProvider(trackId)).value;

    return EditSection(
      title: 'Lyrics',
      subtitle: 'Markdown, with a timestamp on its own line where a new '
          'paragraph starts. A file can be linked instead, and then the file '
          'stays the source of truth.',
      trailing: FilledButton.icon(
        onPressed: () => showLyricsEditorDialog(context, trackId: trackId),
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: Text(stored == null || stored.isEmpty ? 'Write lyrics' : 'Edit lyrics'),
      ),
      child: Text(
        _summary(stored),
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  String _summary(TrackLyrics? stored) {
    if (stored == null || stored.isEmpty) return 'No lyrics yet.';

    final original = stored.original ?? stored.all.first;
    final parsed = original.document;
    final parts = <String>[
      '${parsed.sung.length} paragraph${parsed.sung.length == 1 ? '' : 's'}',
      parsed.isSynced ? 'timed' : 'not timed',
      if (original.isLinked) 'linked to a file',
    ];
    if (stored.translations.isNotEmpty) {
      parts.add(
        '${stored.translations.length} '
        'translation${stored.translations.length == 1 ? '' : 's'}',
      );
    }
    return parts.join(' · ');
  }
}
