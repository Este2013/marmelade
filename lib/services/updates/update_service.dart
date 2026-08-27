import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/logging/app_log.dart';
import '../../domain/version.dart';

/// What a check for updates found.
sealed class UpdateStatus {
  const UpdateStatus();
}

/// The running version is the newest published one.
class UpToDate extends UpdateStatus {
  const UpToDate(this.current);

  final AppVersion current;
}

/// Something newer is published.
class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable({
    required this.current,
    required this.latest,
    required this.url,
    this.notes,
    this.publishedAt,
  });

  final AppVersion current;
  final AppVersion latest;

  /// The release page, which is where a person goes to get it.
  final String url;

  final String? notes;
  final DateTime? publishedAt;
}

/// The check could not be made, or could not be understood.
///
/// A distinct state rather than "up to date": no network is not the same as no
/// update, and quietly reporting the latter is how an app stops being trusted.
class UpdateCheckFailed extends UpdateStatus {
  const UpdateCheckFailed(this.reason, {this.current});

  final String reason;
  final AppVersion? current;
}

/// Asks GitHub whether there is a newer release.
///
/// Read-only and unauthenticated: it fetches the releases list and compares
/// versions. It deliberately does not download or install anything -- an app
/// that fetches an executable and runs it needs signature verification to be
/// safe, and the honest alternative is to open the release page and let the
/// person decide.
class UpdateService {
  UpdateService({
    required this.repository,
    required this.currentVersion,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// `owner/name` on GitHub.
  final String repository;

  /// The version this build reports.
  final String currentVersion;

  final http.Client _client;

  static const _timeout = Duration(seconds: 10);

  /// Checks for a newer release.
  ///
  /// [includePreReleases] follows the channel setting: someone on the stable
  /// channel should not be offered a beta, and someone who opted into betas
  /// should not have to watch for them by hand.
  Future<UpdateStatus> check({bool includePreReleases = false}) async {
    final current = AppVersion.tryParse(currentVersion);
    if (current == null) {
      return UpdateCheckFailed('This build has no readable version number.');
    }

    final uri = Uri.https(
      'api.github.com',
      '/repos/$repository/releases',
      // Enough to find the newest release even when the last few were drafts
      // or pre-releases that this channel ignores.
      const {'per_page': '15'},
    );

    try {
      final response = await _client.get(
        uri,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      ).timeout(_timeout);

      if (response.statusCode == 404) {
        return UpdateCheckFailed(
          'No releases have been published yet.',
          current: current,
        );
      }
      if (response.statusCode != 200) {
        return UpdateCheckFailed(
          'GitHub answered ${response.statusCode}.',
          current: current,
        );
      }

      final body = jsonDecode(response.body);
      if (body is! List) {
        return UpdateCheckFailed(
          'GitHub sent something unreadable.',
          current: current,
        );
      }

      ({AppVersion version, Map<String, dynamic> release})? best;
      for (final entry in body) {
        if (entry is! Map<String, dynamic>) continue;
        if (entry['draft'] == true) continue;
        if (entry['prerelease'] == true && !includePreReleases) continue;

        final tag = entry['tag_name'];
        if (tag is! String) continue;
        final version = AppVersion.tryParse(tag);
        // A tag that is not a version is somebody else's tag.
        if (version == null) continue;
        if (best == null || version > best.version) {
          best = (version: version, release: entry);
        }
      }

      if (best == null) {
        return UpdateCheckFailed(
          includePreReleases
              ? 'No releases found.'
              : 'No stable releases found. Try the beta channel.',
          current: current,
        );
      }

      if (!(best.version > current)) return UpToDate(current);

      final publishedAt = best.release['published_at'];
      final notes = best.release['body'];
      return UpdateAvailable(
        current: current,
        latest: best.version,
        url: best.release['html_url'] as String? ??
            'https://github.com/$repository/releases',
        notes: notes is String && notes.trim().isNotEmpty ? notes.trim() : null,
        publishedAt:
            publishedAt is String ? DateTime.tryParse(publishedAt) : null,
      );
    } catch (error) {
      // Offline, DNS, a proxy, a rate limit: all the same to someone looking
      // at the screen, and none of them mean "up to date".
      AppLog.instance.warn(
        'the update check could not reach GitHub',
        fields: {'error': '$error'},
      );
      return UpdateCheckFailed(
        'Could not reach GitHub. Check your connection.',
        current: current,
      );
    }
  }

  void dispose() => _client.close();
}
