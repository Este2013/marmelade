import 'package:flutter/material.dart';

/// A centred message for a view with nothing to show.
///
/// Empty states get real design attention here because a fresh install and a
/// filtered-to-nothing list are both common, and "blank screen" tells the user
/// nothing about which of the two happened.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// A primary action, when there is an obvious next step.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 56,
                color: theme.colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.55),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: 24),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The empty state for a library with no music in it yet.
class LibraryEmptyState extends StatelessWidget {
  const LibraryEmptyState({super.key, this.onAddFolder});

  final VoidCallback? onAddFolder;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.library_music_outlined,
      title: 'No music yet',
      message: 'Point marmelade at a folder and it will index everything '
          'inside, working out who played what as it goes.',
      action: onAddFolder == null
          ? null
          : FilledButton.icon(
              onPressed: onAddFolder,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('Add a music folder'),
            ),
    );
  }
}
