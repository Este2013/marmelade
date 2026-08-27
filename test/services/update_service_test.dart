import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marmelade/services/updates/update_service.dart';

/// The update check, against a stubbed GitHub.
///
/// The rule the whole thing rests on: only say "up to date" when that is
/// actually known. Every other outcome -- offline, rate limited, no releases,
/// unreadable answer -- is a failure state that says so, because an app that
/// reports "up to date" when it could not check is an app whose update check
/// nobody should believe.
void main() {
  UpdateService serviceFor(
    Object? body, {
    int status = 200,
    String current = '1.0.0',
    Exception? throws,
  }) =>
      UpdateService(
        repository: 'Este2013/marmelade',
        currentVersion: current,
        client: MockClient((request) async {
          if (throws != null) throw throws;
          return http.Response(
            jsonEncode(body),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

  Map<String, dynamic> release(
    String tag, {
    bool draft = false,
    bool prerelease = false,
    String? notes,
  }) =>
      {
        'tag_name': tag,
        'draft': draft,
        'prerelease': prerelease,
        'html_url': 'https://github.com/Este2013/marmelade/releases/tag/$tag',
        'published_at': '2026-08-01T10:00:00Z',
        'body': ?notes,
      };

  group('finding a newer release', () {
    test('a newer tag is offered, with where to get it', () async {
      final status = await serviceFor([release('v1.1.0', notes: 'Fixes')])
          .check();

      expect(status, isA<UpdateAvailable>());
      final available = status as UpdateAvailable;
      expect(available.latest.toString(), '1.1.0');
      expect(available.url, endsWith('/tag/v1.1.0'));
      expect(available.notes, 'Fixes');
      expect(available.publishedAt, isNotNull);
    });

    test('the newest is chosen, not the first listed', () async {
      final status = await serviceFor([
        release('v1.0.1'),
        release('v1.2.0'),
        release('v1.1.0'),
      ]).check();

      expect((status as UpdateAvailable).latest.toString(), '1.2.0');
    });

    test('the same version is up to date', () async {
      expect(await serviceFor([release('v1.0.0')]).check(), isA<UpToDate>());
    });

    test('an older published tag is not an update', () async {
      // It happens: a hotfix branch tagged after the release it precedes.
      final status =
          await serviceFor([release('v0.9.0')], current: '1.0.0').check();
      expect(status, isA<UpToDate>());
    });
  });

  group('what gets skipped', () {
    test('drafts never count', () async {
      // Alongside the published release, which is the shape a repository is
      // actually in while the next version is being prepared.
      final status = await serviceFor([
        release('v2.0.0', draft: true),
        release('v1.0.0'),
      ]).check();
      expect(status, isA<UpToDate>());
    });

    test('pre-releases are ignored unless asked for', () async {
      final body = [
        release('v1.1.0-beta.1', prerelease: true),
        release('v1.0.0'),
      ];
      expect(await serviceFor(body).check(), isA<UpToDate>());
      expect(
        await serviceFor(body).check(includePreReleases: true),
        isA<UpdateAvailable>(),
      );
    });

    test('a channel with nothing in it says so rather than "up to date"',
        () async {
      // Only a beta exists. On the stable channel that is not "you are up to
      // date" -- it is "this channel has nothing", which is worth saying.
      final status =
          await serviceFor([release('v1.1.0-beta.1', prerelease: true)])
              .check();
      expect(status, isA<UpdateCheckFailed>());
      expect((status as UpdateCheckFailed).reason, contains('beta channel'));
    });

    test('a tag that is not a version is skipped', () async {
      final status = await serviceFor([
        release('nightly'),
        release('v1.1.0'),
      ]).check();
      expect((status as UpdateAvailable).latest.toString(), '1.1.0');
    });
  });

  group('when it cannot tell', () {
    test('a network failure is a failure, not "up to date"', () async {
      final status =
          await serviceFor(null, throws: Exception('offline')).check();
      expect(status, isA<UpdateCheckFailed>());
      expect((status as UpdateCheckFailed).reason, contains('Could not reach'));
    });

    test('a rate limit says so rather than lying', () async {
      final status = await serviceFor(const [], status: 403).check();
      expect(status, isA<UpdateCheckFailed>());
      expect((status as UpdateCheckFailed).reason, contains('403'));
    });

    test('no releases at all is not an update', () async {
      final status = await serviceFor(const []).check();
      expect(status, isA<UpdateCheckFailed>());
      expect((status as UpdateCheckFailed).reason, contains('No stable'));
    });

    test('a 404 explains itself', () async {
      final status = await serviceFor(const [], status: 404).check();
      expect(
        (status as UpdateCheckFailed).reason,
        contains('No releases have been published'),
      );
    });

    test('an unreadable answer is a failure', () async {
      final status = await serviceFor({'message': 'nope'}).check();
      expect(status, isA<UpdateCheckFailed>());
    });

    test('a build with no readable version cannot check', () async {
      final status =
          await serviceFor([release('v2.0.0')], current: 'dev').check();
      expect(status, isA<UpdateCheckFailed>());
    });
  });
}
