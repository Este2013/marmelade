/// A released version, and how two of them compare.
///
/// Small on purpose. The update check has to decide one thing -- is what is
/// published newer than what is running -- and getting that wrong in either
/// direction is bad: nagging about an update that is actually older, or never
/// mentioning one that is newer.
///
/// Follows semantic versioning far enough to be right about real tags:
/// `v1.2.3`, `1.2.3`, `1.2.3+4` (the build number, which Flutter appends and
/// which never decides ordering), and `1.2.3-beta.2` (a pre-release, which
/// sorts *before* the release it leads to).
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(
    this.major,
    this.minor,
    this.patch, {
    this.preRelease = const [],
  });

  final int major;
  final int minor;
  final int patch;

  /// The dot-separated parts after a `-`, empty for a normal release.
  final List<String> preRelease;

  bool get isPreRelease => preRelease.isNotEmpty;

  /// Parses a version string, returning null when it is not one.
  ///
  /// Null rather than a throw or a zero: a repository whose tags are not
  /// versions should make the update check say "could not tell", not "you are
  /// up to date" and not crash.
  static AppVersion? tryParse(String text) {
    var value = text.trim();
    if (value.toLowerCase().startsWith('v')) value = value.substring(1);

    // Flutter's build number. It distinguishes builds of the same version, and
    // never decides which version is newer.
    final plus = value.indexOf('+');
    if (plus >= 0) value = value.substring(0, plus);

    var preRelease = const <String>[];
    final dash = value.indexOf('-');
    if (dash >= 0) {
      preRelease = value
          .substring(dash + 1)
          .split('.')
          .where((part) => part.isNotEmpty)
          .toList();
      value = value.substring(0, dash);
    }

    final parts = value.split('.');
    if (parts.isEmpty || parts.length > 3) return null;

    final numbers = <int>[];
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0) return null;
      numbers.add(number);
    }

    return AppVersion(
      numbers[0],
      numbers.length > 1 ? numbers[1] : 0,
      numbers.length > 2 ? numbers[2] : 0,
      preRelease: preRelease,
    );
  }

  @override
  int compareTo(AppVersion other) {
    final byMajor = major.compareTo(other.major);
    if (byMajor != 0) return byMajor;
    final byMinor = minor.compareTo(other.minor);
    if (byMinor != 0) return byMinor;
    final byPatch = patch.compareTo(other.patch);
    if (byPatch != 0) return byPatch;

    // A pre-release comes before the release it leads to: 1.2.0-beta < 1.2.0.
    if (isPreRelease != other.isPreRelease) return isPreRelease ? -1 : 1;
    if (!isPreRelease) return 0;

    for (var i = 0; i < preRelease.length && i < other.preRelease.length; i++) {
      final mine = preRelease[i];
      final theirs = other.preRelease[i];
      final mineNumber = int.tryParse(mine);
      final theirsNumber = int.tryParse(theirs);
      // Numeric parts compare as numbers, so beta.9 comes before beta.10.
      // Anything else compares as text, and per semver a numeric identifier
      // ranks *below* an alphanumeric one -- the intuition runs the other way.
      final result = switch ((mineNumber, theirsNumber)) {
        (final a?, final b?) => a.compareTo(b),
        (null, _?) => 1,
        (_?, null) => -1,
        _ => mine.compareTo(theirs),
      };
      if (result != 0) return result;
    }
    return preRelease.length.compareTo(other.preRelease.length);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;
  bool operator <(AppVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease.join('.'));

  @override
  String toString() {
    final base = '$major.$minor.$patch';
    return isPreRelease ? '$base-${preRelease.join('.')}' : base;
  }
}
