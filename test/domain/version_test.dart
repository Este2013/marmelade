import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/domain/version.dart';

/// Version comparison, which decides whether the app nags about an update.
///
/// Wrong in one direction is a notice about a version older than the one
/// running; wrong in the other is never mentioning a real release. Both are
/// worse than the feature not existing.
void main() {
  AppVersion v(String text) => AppVersion.tryParse(text)!;

  group('parsing', () {
    test('reads the tags a repository actually carries', () {
      expect(v('1.2.3').toString(), '1.2.3');
      expect(v('v1.2.3').toString(), '1.2.3');
      expect(v('V1.2.3').toString(), '1.2.3');
      // Flutter's own version string, build number and all.
      expect(v('1.0.0+42').toString(), '1.0.0');
      expect(v('2.0').toString(), '2.0.0');
      expect(v('3').toString(), '3.0.0');
      expect(v('1.2.3-beta.2').toString(), '1.2.3-beta.2');
    });

    test('something that is not a version is null, not zero', () {
      // A repository whose tags are not versions should make the check say it
      // could not tell, rather than "you are up to date".
      for (final text in [
        'latest',
        'release-2024',
        '',
        'v',
        '1.2.3.4',
        '1.-2.3',
        'one.two.three',
      ]) {
        expect(AppVersion.tryParse(text), isNull, reason: text);
      }
    });
  });

  group('ordering', () {
    test('compares part by part, not as text', () {
      // The trap: "1.10.0" sorts before "1.9.0" as a string.
      expect(v('1.10.0') > v('1.9.0'), isTrue);
      expect(v('2.0.0') > v('1.99.99'), isTrue);
      expect(v('1.2.10') > v('1.2.9'), isTrue);
    });

    test('the build number never decides', () {
      expect(v('1.0.0+9'), v('1.0.0+1'));
    });

    test('a pre-release comes before the release it leads to', () {
      expect(v('1.2.0-beta.1') < v('1.2.0'), isTrue);
      expect(v('1.2.0') > v('1.2.0-rc.5'), isTrue);
    });

    test('numeric pre-release parts compare as numbers', () {
      expect(v('1.0.0-beta.10') > v('1.0.0-beta.9'), isTrue);
    });

    test('a named pre-release outranks a numbered one', () {
      // Semver, section 11: numeric identifiers have *lower* precedence than
      // alphanumeric ones. The intuition runs the other way, which is why it
      // is written down here.
      expect(v('1.0.0-alpha') > v('1.0.0-2'), isTrue);
    });

    test('more parts is further along than fewer', () {
      expect(v('1.0.0-beta.1') > v('1.0.0-beta'), isTrue);
    });

    test('equal versions are equal', () {
      expect(v('1.2.3') == v('1.2.3'), isTrue);
      expect(v('1.2.3') == v('v1.2.3+7'), isTrue);
    });
  });
}
