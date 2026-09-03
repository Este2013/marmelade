import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/lyrics_repository.dart';
import '../lyrics/lyrics_editor_dialog.dart';

/// Where lyrics stand for this track, with a way in to change them.
///
/// The whole card opens [LyricsEditorDialog] -- writing and timing lyrics
/// wants more room than one card in a long form has to give it.
class LyricsSection extends ConsumerWidget {
  const LyricsSection({super.key, required this.trackId});

  final int trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stored = ref.watch(trackLyricsProvider(trackId)).value;
    final hasLyrics = stored != null && !stored.isEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showLyricsEditorDialog(context, trackId: trackId),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasLyrics ? 'Edit lyrics' : 'Start writing lyrics',
                      style: theme.textTheme.titleMedium,
                    ),
                    if (hasLyrics) ...[
                      const SizedBox(height: 4),
                      Text(
                        _summary(stored),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.open_in_full, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  String _summary(TrackLyrics stored) {
    final original = stored.original ?? stored.all.first;
    final parsed = original.document;
    return '${parsed.sung.length} paragraph${parsed.sung.length == 1 ? '' : 's'}'
        ' · ${parsed.isSynced ? 'timed' : 'not timed'}';
  }
}
