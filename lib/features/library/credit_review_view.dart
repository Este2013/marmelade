import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/review_repository.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';

/// The credits the resolver refused to guess at, and the decision for each.
///
/// The resolver is deliberately unwilling to split a credit it cannot
/// corroborate, because a wrong split invents an artist that never existed.
/// This is where the remainder gets settled by someone who can actually tell.
///
/// One card per credit *string*, not per track: the same field usually appears
/// on every track of a release, and answering the same question twenty times is
/// not review, it is data entry.
class CreditReviewView extends ConsumerWidget {
  const CreditReviewView({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingCreditsProvider);
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 24, 12),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 8),
              Text('Credits to review', style: theme.textTheme.headlineSmall),
              const SizedBox(width: 12),
              Text(
                pluralize(pending.value?.length ?? 0, 'credit'),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Expanded(
          child: pending.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not load the review queue',
              message: '$error',
            ),
            data: (groups) {
              if (groups.isEmpty) {
                return const EmptyState(
                  icon: Icons.done_all,
                  title: 'Nothing to review',
                  message: 'Every credit in the library has been resolved. New '
                      'ones will appear here when a scan finds a name it '
                      'cannot confidently split.',
                );
              }
              // Capped rather than full-width: a card is a short question with
              // two name fields, and stretching it across a wide monitor puts
              // the answer buttons a screen away from the question.
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    itemCount: groups.length,
                    itemBuilder: (context, index) => _ReviewCard(
                      // Keyed on the credit string so the editable fields
                      // follow their card as the list shrinks under them.
                      key: ValueKey(groups[index].rawCredit),
                      group: groups[index],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One credit string, its suggested reading, and the decision.
class _ReviewCard extends ConsumerStatefulWidget {
  const _ReviewCard({super.key, required this.group});

  final PendingCreditGroup group;

  @override
  ConsumerState<_ReviewCard> createState() => _ReviewCardState();
}

class _ReviewCardState extends ConsumerState<_ReviewCard> {
  /// One controller per suggested part, so a name can be corrected before it is
  /// committed. A parked credit is often parked precisely because it needs a
  /// small fix, and offering only yes/no would waste the visit.
  late List<TextEditingController> _controllers = _buildControllers();

  var _busy = false;

  List<TextEditingController> _buildControllers() => [
        for (final part in widget.group.parts)
          TextEditingController(text: part.creditedAs),
      ];

  @override
  void didUpdateWidget(_ReviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.group.rawCredit != oldWidget.group.rawCredit) {
      for (final controller in _controllers) {
        controller.dispose();
      }
      _controllers = _buildControllers();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final repository = ref.read(reviewRepositoryProvider);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    group.rawCredit,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 12),
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.music_note_outlined, size: 16),
                  label: Text(pluralize(group.trackCount, 'track')),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // The resolver's own words. Showing the reasoning rather than a
            // bare confidence number is what makes the decision answerable.
            Text(
              group.reason,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (group.sampleTitles.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'On ${group.sampleTitles.join(', ')}'
                '${group.trackCount > group.sampleTitles.length ? ' and '
                    '${group.trackCount - group.sampleTitles.length} more' : ''}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 18),
            if (group.hasSplit) ...[
              Text(
                'Split into',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < _controllers.length; i++)
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _controllers[i],
                        enabled: !_busy,
                        decoration: InputDecoration(
                          isDense: true,
                          border: const OutlineInputBorder(),
                          labelText: group.parts[i].segmentRoleLabel,
                          suffixIcon: group.parts[i].artistIds.isEmpty
                              ? null
                              : Tooltip(
                                  message: 'Already an artist in your library',
                                  child: Icon(Icons.check_circle_outline,
                                      size: 18, color: scheme.primary),
                                ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
            ],
            Row(
              children: [
                if (group.hasSplit)
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() => repository.applySplit(
                              group,
                              [
                                for (var i = 0; i < _controllers.length; i++)
                                  group.parts[i]
                                      .withName(_controllers[i].text),
                              ],
                            )),
                    icon: const Icon(Icons.call_split, size: 18),
                    label: const Text('Split'),
                  ),
                if (group.hasSplit) const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() => repository.keepWhole(group)),
                  icon: const Icon(Icons.person_outline, size: 18),
                  label: const Text('Keep as one artist'),
                ),
                const Spacer(),
                TextButton(
                  onPressed:
                      _busy ? null : () => _run(() => repository.dismiss(group)),
                  child: const Text('Skip'),
                ),
              ],
            ),
            if (!group.hasSplit) ...[
              const SizedBox(height: 8),
              Text(
                'No alternative reading was recorded for this one, so the '
                'choice is to accept it as a name or leave it for later.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

extension on CreditOption {
  /// A field label naming what this part would be credited as.
  String get segmentRoleLabel => switch (role) {
        'featured' => 'Featured artist',
        'remixer' => 'Remixer',
        _ => 'Artist',
      };
}
