import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/changelog/changelog.dart';

/// Shows release notes: one version, or the whole history.
///
/// [versions] is what to show. Null means everything known, which is the
/// built-in changelog with the published one layered over it -- so the history
/// is complete offline and complete before the first fetch lands.
Future<void> showChangelog(
  BuildContext context, {
  List<ReleaseNotes>? versions,
  String title = 'Release history',
  String? subtitle,
}) =>
    showDialog<void>(
      context: context,
      builder: (context) => _ChangelogDialog(
        versions: versions,
        title: title,
        subtitle: subtitle,
      ),
    );

class _ChangelogDialog extends ConsumerWidget {
  const _ChangelogDialog({
    required this.title,
    this.versions,
    this.subtitle,
  });

  final String title;
  final List<ReleaseNotes>? versions;
  final String? subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Only reached for the "everything" case; a caller that passed a list has
    // already decided and should not wait on a network read.
    final all = versions ?? ref.watch(changelogProvider).value;

    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 480,
        child: switch (all) {
          null => const Center(child: CircularProgressIndicator()),
          final list when list.isEmpty => Center(
              child: Text(
                'No release notes yet.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          final list => ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, index) => _Version(
                notes: list[index],
                isFirst: index == 0,
              ),
            ),
        },
      ),
      actions: [
        if (versions != null)
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              showChangelog(context);
            },
            child: const Text('All versions'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// One version's notes, grouped by kind.
class _Version extends StatelessWidget {
  const _Version({required this.notes, required this.isFirst});

  final ReleaseNotes notes;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 0 : 24, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                notes.version,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              Text(
                notes.date ?? 'not released yet',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          if (notes.headline != null) ...[
            const SizedBox(height: 6),
            Text(
              notes.headline!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          for (final kind in ChangeKind.values)
            if (notes.ofKind(kind).isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                kind.label.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              for (final change in notes.ofKind(kind))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 7, right: 10),
                        child: Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: scheme.onSurfaceVariant,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          change.text,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
        ],
      ),
    );
  }
}
