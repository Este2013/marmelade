import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/missing_files_repository.dart';

/// What to do about songs whose files are gone.
///
/// Only here when there is something to say. A settings page that lists a
/// problem nobody has is noise, and one that stays silent while the library
/// fills with songs that will not play is worse -- so this appears the moment
/// a scan cannot find something and goes away by itself when the drive comes
/// back.
class MissingFilesSection extends ConsumerWidget {
  const MissingFilesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(missingSummaryProvider).value ?? MissingSummary.none;
    if (!summary.any) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(Icons.link_off, color: theme.colorScheme.error),
            title: Text(describeMissing(summary)),
            subtitle: const Text(
              'They are still listed with everything known about them, because '
              'a file usually goes missing for a while rather than for good -- '
              'a drive left at home, a folder being reorganised.',
            ),
          ),
          SwitchListTile(
            title: const Text('Keep them out of the lists'),
            subtitle: const Text(
              'Nothing is deleted: they come back on their own when the files '
              'do.',
            ),
            value: ref.watch(hideMissingProvider),
            onChanged: (value) =>
                ref.read(hideMissingProvider.notifier).set(value),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: () => showMissingTracks(context, ref),
                  icon: const Icon(Icons.list_alt_outlined),
                  label: const Text('Show what is missing'),
                ),
                TextButton.icon(
                  onPressed: () => confirmRemoveMissing(context, ref, summary),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove them from the library'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One sentence for a count, used by both the banner and the settings card.
String describeMissing(MissingSummary summary) {
  final songs = summary.tracks == 1
      ? '1 song is missing its file'
      : '${summary.tracks} songs are missing their files';
  if (summary.albums == 0) return '$songs.';
  return '$songs, including '
      '${summary.albums} ${summary.albums == 1 ? 'album' : 'albums'} '
      'that ${summary.albums == 1 ? 'is' : 'are'} gone entirely.';
}

/// The list, because a count is not enough to decide by.
Future<void> showMissingTracks(BuildContext context, WidgetRef ref) async {
  final tracks = await ref.read(missingFilesRepositoryProvider).list();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Missing files'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: tracks.isEmpty
            ? const Center(child: Text('Nothing is missing any more.'))
            : ListView.builder(
                itemCount: tracks.length,
                itemBuilder: (context, index) {
                  final track = tracks[index];
                  return ListTile(
                    dense: true,
                    title: Text(track.title),
                    // The path is usually what identifies it: two songs can
                    // share a title, but the folder says which drive it was
                    // on.
                    subtitle: Text(
                      track.path ?? track.album ?? 'No known location',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Asks before removing, and is specific about what goes with them.
Future<void> confirmRemoveMissing(
  BuildContext context,
  WidgetRef ref,
  MissingSummary summary,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Remove them?'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(describeMissing(summary)),
            const SizedBox(height: 12),
            // Said plainly, because this is the part that cannot be undone
            // and the part people do not think of: the files are gone either
            // way, but the work put into describing them need not be.
            const Text(
              'Their tags, ratings, play counts and lyrics go with them, and '
              'that cannot be undone. If the files are only unplugged, hiding '
              'them keeps all of it until they are back.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Artists keep their pictures, links and aliases -- none of that '
              'came from the files.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Keep them'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final removed = await ref.read(missingFilesRepositoryProvider).removeMissing();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(
      'Removed ${removed.tracks} ${removed.tracks == 1 ? 'song' : 'songs'}'
      '${removed.albums == 0 ? '' : ' and ${removed.albums} '
          '${removed.albums == 1 ? 'album' : 'albums'}'}.',
    ),
  ));
}
