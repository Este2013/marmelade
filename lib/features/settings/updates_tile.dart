import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../data/repositories/settings_repository.dart' show SettingKeys;
import '../../services/updates/update_service.dart';

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
                  if (available.notes != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      available.notes!,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onPrimaryContainer),
                    ),
                  ],
                ],
              ),
            ),
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
