import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../data/repositories/settings_repository.dart' show SettingKeys;
import '../../core/changelog/changelog.dart';
import '../../services/updates/update_service.dart';
import 'changelog_dialog.dart';

/// The version, and whether there is a newer one.
///
/// The check is manual by default and never installs anything: it opens the
/// release page. An app that downloads an executable and runs it needs
/// signature verification to be safe, and until there is one, handing the
/// person the page is the honest version of this feature.
class UpdatesTile extends ConsumerStatefulWidget {
  const UpdatesTile({super.key});

  @override
  ConsumerState<UpdatesTile> createState() => _UpdatesTileState();
}

class _UpdatesTileState extends ConsumerState<UpdatesTile> {
  UpdateStatus? _status;
  var _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      final service = await ref.read(updateServiceProvider.future);
      final status = await service.check(
        includePreReleases: ref.read(updateChannelProvider),
      );
      if (!mounted) return;
      setState(() => _status = status);
      await ref.read(settingsRepositoryProvider).set(
            SettingKeys.lastUpdateCheck,
            DateTime.now().toUtc().toIso8601String(),
          );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = ref.watch(appVersionProvider).value;
    final beta = ref.watch(updateChannelProvider);
    final upcoming = ref.watch(upcomingChangesProvider).value ?? const [];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: Text(
            version == null ? 'marmelade' : 'marmelade $version',
          ),
          subtitle: Text(_subtitle()),
          trailing: _checking
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : OutlinedButton(
                  onPressed: _check,
                  child: const Text('Check for updates'),
                ),
        ),
        if (_status case final UpdateAvailable available)
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.download_outlined,
                          size: 18, color: scheme.onPrimaryContainer),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'marmelade ${available.latest} is out',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () => launchUrl(Uri.parse(available.url)),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Open the release'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // The published changelog when there is one, and GitHub's
                  // generated notes otherwise: a hand-written line about what
                  // changed beats a list of commit subjects, but a list of
                  // commit subjects beats nothing.
                  if (upcoming.isNotEmpty)
                    _UpcomingSummary(versions: upcoming)
                  else if (available.notes != null)
                    Text(
                      available.notes!,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onPrimaryContainer),
                    ),
                ],
              ),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Release notes'),
          subtitle: Text(
            version == null
                ? 'What each version changed.'
                : 'What changed in $version, and in every version before it.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            final current = ref.read(currentChangesProvider).value;
            showChangelog(
              context,
              versions: current == null ? null : [current],
              title: current == null
                  ? 'Release history'
                  : 'What is new in ${current.version}',
              subtitle: current == null
                  ? null
                  : 'The version you are running.',
            );
          },
        ),
        SwitchListTile(
          secondary: const Icon(Icons.science_outlined),
          title: const Text('Include pre-releases'),
          subtitle: const Text(
            'Offers betas as well as finished releases.',
          ),
          value: beta,
          onChanged: (value) =>
              ref.read(updateChannelProvider.notifier).set(value),
        ),
      ],
    );
  }

  /// What the check last said, in one line.
  String _subtitle() => switch (_status) {
        null => 'Checks GitHub when you ask it to. Nothing is downloaded or '
            'installed for you.',
        UpToDate() => 'This is the newest release.',
        UpdateAvailable(:final latest) => 'Version $latest is available.',
        // Said plainly, because "could not check" and "up to date" are
        // different answers and only one of them is known.
        UpdateCheckFailed(:final reason) => reason,
      };
}

/// What the versions ahead of this one bring, in the update banner.
class _UpcomingSummary extends StatelessWidget {
  const _UpcomingSummary({required this.versions});

  final List<ReleaseNotes> versions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = Theme.of(context).colorScheme;
    // Flattened across versions: someone three releases behind wants to know
    // what they are getting, not which release each line came from.
    final changes = [for (final version in versions) ...version.changes];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final change in changes.take(4))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '• ${change.text}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onPrimaryContainer),
            ),
          ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: () => showChangelog(
            context,
            versions: versions,
            title: 'What an update brings',
            subtitle: changes.length > 4
                ? '${changes.length} changes across '
                    '${versions.length} version${versions.length == 1 ? '' : 's'}'
                : null,
          ),
          child: Text(
            changes.length > 4 ? 'All ${changes.length} changes' : 'Details',
          ),
        ),
      ],
    );
  }
}
