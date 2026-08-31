import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/changelog/changelog.dart';
import '../../core/logging/app_log.dart';
import '../../domain/version.dart';

/// The changelog, from the two places it comes from.
///
/// The build carries its own, which answers "what changed in the version I am
/// running" instantly and offline. The published copy on GitHub Pages answers
/// the other question -- what a newer version would bring -- which no build can
/// know about itself.
///
/// Merged, not chosen between: the published copy wins where they overlap
/// because it is newer, and the built-in one fills in whatever the network did
/// not deliver. So the history is complete even offline, and complete even
/// before the first fetch succeeds.
class ChangelogService {
  ChangelogService({required this.url, http.Client? client})
      : _client = client ?? http.Client();

  /// Where CI publishes the generated JSON.
  final String url;

  final http.Client _client;

  static const _timeout = Duration(seconds: 8);

  /// Fetches the published changelog, or null when it cannot be had.
  ///
  /// Null rather than an empty list: "the network did not answer" and "there
  /// are no releases" would otherwise look the same, and only one of them
  /// should replace a cached copy.
  Future<List<ReleaseNotes>?> fetch() async {
    try {
      final response =
          await _client.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode != 200) {
        AppLog.instance.debug(
          'the changelog is not published yet',
          fields: {'status': response.statusCode, 'url': url},
        );
        return null;
      }
      return parse(response.body);
    } catch (error) {
      AppLog.instance.debug(
        'the changelog could not be fetched',
        fields: {'error': '$error'},
      );
      return null;
    }
  }

  /// Reads the published shape. Returns null when it is not that shape.
  static List<ReleaseNotes>? parse(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return null;
      final versions = json['versions'];
      if (versions is! List) return null;
      return [
        for (final entry in versions) ?ReleaseNotes.fromJson(entry),
      ];
    } catch (_) {
      return null;
    }
  }

  /// The built-in changelog and [published], newest first.
  static List<ReleaseNotes> merge(List<ReleaseNotes>? published) {
    final byVersion = <String, ReleaseNotes>{
      for (final release in changelog) release.version: release,
    };
    for (final release in published ?? const <ReleaseNotes>[]) {
      byVersion[release.version] = release;
    }

    final all = byVersion.values.toList()
      ..sort((a, b) {
        final left = AppVersion.tryParse(a.version);
        final right = AppVersion.tryParse(b.version);
        // A version that will not parse sorts last rather than throwing: the
        // published file is data from outside this build.
        if (left == null || right == null) return left == null ? 1 : -1;
        return right.compareTo(left);
      });
    return all;
  }

  /// The versions newer than [current], which is what an update would bring.
  static List<ReleaseNotes> newerThan(
    String current,
    List<ReleaseNotes> all,
  ) {
    final running = AppVersion.tryParse(current);
    if (running == null) return const [];
    return [
      for (final release in all)
        if (AppVersion.tryParse(release.version) case final version?)
          if (version > running) release,
    ];
  }

  void dispose() => _client.close();
}
