import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marmelade/core/changelog/changelog.dart';
import 'package:marmelade/services/updates/changelog_service.dart';

/// The changelog, from the two places it comes from.
///
/// The published copy is data from outside the build -- written by a workflow,
/// served from a static host, possibly older than the app, possibly absent.
/// Every test here is about not letting that break the history the app can
/// already show from its own compiled-in copy.
void main() {
  String published(List<Map<String, Object?>> versions) =>
      jsonEncode({'schema': 1, 'versions': versions});

  ChangelogService serviceFor(String body, {int status = 200}) =>
      ChangelogService(
        url: 'https://example.invalid/changelog.json',
        client: MockClient(
          (request) async => http.Response(body, status),
        ),
      );

  group('fetching', () {
    test('a published changelog is read', () async {
      final fetched = await serviceFor(published([
        {
          'version': '9.0.0',
          'date': '2026-09-01',
          'headline': 'Later than anything built in',
          'changes': [
            {'kind': 'added', 'text': 'A thing'},
          ],
        }
      ])).fetch();

      expect(fetched, isNotNull);
      expect(fetched!.single.version, '9.0.0');
      expect(fetched.single.headline, 'Later than anything built in');
      expect(fetched.single.changes.single.kind, ChangeKind.added);
    });

    test('a failure is null, not an empty list', () async {
      // "The network did not answer" and "there are no releases" must not look
      // the same: only one of them should replace a cached copy.
      expect(await serviceFor('', status: 500).fetch(), isNull);
      expect(await serviceFor('not json').fetch(), isNull);
      expect(await serviceFor(jsonEncode({'nope': true})).fetch(), isNull);
    });

    test('an entry with no version is skipped, not fatal', () async {
      final fetched = await serviceFor(published([
        {'changes': const []},
        {
          'version': '9.0.0',
          'changes': [
            {'kind': 'fixed', 'text': 'Something'},
          ],
        },
      ])).fetch();

      expect(fetched!.map((r) => r.version), ['9.0.0']);
    });

    test('an unknown change kind reads as "changed"', () async {
      // A later version of the app may add kinds this one has never heard of.
      final fetched = await serviceFor(published([
        {
          'version': '9.0.0',
          'changes': [
            {'kind': 'deprecated', 'text': 'Something'},
          ],
        }
      ])).fetch();

      expect(fetched!.single.changes.single.kind, ChangeKind.changed);
    });
  });

  group('merging', () {
    test('nothing published still gives the built-in history', () {
      final merged = ChangelogService.merge(null);
      expect(merged, isNotEmpty);
      expect(merged.map((r) => r.version), contains(changelog.first.version));
    });

    test('the published copy wins where they overlap', () {
      // It is newer than the build: a typo fixed on the site should show.
      final merged = ChangelogService.merge([
        ReleaseNotes(
          version: changelog.first.version,
          date: '2099-01-01',
          changes: const [Change.fixed('Corrected on the website')],
        ),
      ]);

      final entry =
          merged.firstWhere((r) => r.version == changelog.first.version);
      expect(entry.date, '2099-01-01');
      expect(entry.changes.single.text, 'Corrected on the website');
    });

    test('versions come back newest first', () {
      final merged = ChangelogService.merge(const [
        ReleaseNotes(version: '0.2.0', changes: []),
        ReleaseNotes(version: '9.10.0', changes: []),
        ReleaseNotes(version: '9.9.0', changes: []),
      ]);

      // 9.10.0 above 9.9.0: sorted as versions, not as text.
      expect(merged.first.version, '9.10.0');
      expect(merged[1].version, '9.9.0');
    });

    test('a version that will not parse sorts last instead of throwing', () {
      final merged = ChangelogService.merge(const [
        ReleaseNotes(version: 'nightly', changes: []),
        ReleaseNotes(version: '9.0.0', changes: []),
      ]);

      expect(merged.first.version, '9.0.0');
      expect(merged.last.version, 'nightly');
    });
  });

  group('what an update would bring', () {
    final all = ChangelogService.merge(const [
      ReleaseNotes(version: '1.2.0', changes: [Change.added('c')]),
      ReleaseNotes(version: '1.1.0', changes: [Change.added('b')]),
      ReleaseNotes(version: '1.0.0', changes: [Change.added('a')]),
    ]);

    test('only versions above the one running', () {
      final newer = ChangelogService.newerThan('1.0.0', all);
      expect(newer.map((r) => r.version), ['1.2.0', '1.1.0']);
    });

    test('nothing when running the newest', () {
      expect(ChangelogService.newerThan('1.2.0', all), isEmpty);
    });

    test('a pre-release is behind its release', () {
      final newer = ChangelogService.newerThan('1.2.0-beta.1', all);
      expect(newer.map((r) => r.version), contains('1.2.0'));
    });

    test('an unreadable running version offers nothing', () {
      // Rather than offering every version as an upgrade.
      expect(ChangelogService.newerThan('dev', all), isEmpty);
    });
  });

  group('the built-in changelog itself', () {
    test('every entry has a parseable version and some changes', () {
      // It is hand-written, and a typo here would show up in the app and on
      // the website at the same time.
      for (final release in changelog) {
        expect(
          RegExp(r'^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$').hasMatch(release.version),
          isTrue,
          reason: release.version,
        );
        expect(release.changes, isNotEmpty, reason: release.version);
        for (final change in release.changes) {
          expect(change.text.trim(), isNotEmpty);
        }
      }
    });

    test('a dated entry uses the format the site and the gate expect', () {
      // '2026-8-31' would sort and render wrongly while looking fine in the
      // source, and the release gate only checks that a date is *present*.
      for (final release in changelog) {
        if (release.date == null) continue;
        expect(
          RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(release.date!),
          isTrue,
          reason: '${release.version} has date "${release.date}"',
        );
        expect(
          DateTime.tryParse(release.date!),
          isNotNull,
          reason: '${release.version} has an impossible date',
        );
      }
    });

    test('versions appear once each, newest first', () {
      final versions = [for (final r in changelog) r.version];
      expect(versions.toSet().length, versions.length);
      expect(
        versions,
        ChangelogService.merge(null).map((r) => r.version).toList(),
      );
    });

    test('a JSON round trip keeps everything', () {
      // The website and the app read the same file; a field lost in encoding
      // would be a line that silently stops being published.
      final encoded = jsonEncode({
        'schema': 1,
        'versions': [for (final r in changelog) r.toJson()],
      });
      final decoded = ChangelogService.parse(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.length, changelog.length);
      for (var i = 0; i < changelog.length; i++) {
        expect(decoded[i].version, changelog[i].version);
        expect(decoded[i].headline, changelog[i].headline);
        expect(decoded[i].date, changelog[i].date);
        expect(
          decoded[i].changes.map((c) => '${c.kind.name}:${c.text}'),
          changelog[i].changes.map((c) => '${c.kind.name}:${c.text}'),
        );
      }
    });
  });
}
