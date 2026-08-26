import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/enums.dart';
import 'image_probe.dart';

/// An image file found next to music, and how good a match it is.
class ArtCandidate {
  const ArtCandidate({
    required this.file,
    required this.role,
    required this.score,
    required this.reason,
    required this.info,
  });

  final File file;
  final ImageRole role;

  /// Higher wins. Only meaningful relative to other candidates.
  final int score;

  /// Why this file was picked, shown in the debug view. Worth keeping: "why is
  /// this the cover?" is otherwise an unanswerable question.
  final String reason;

  final ImageInfo info;

  @override
  String toString() =>
      'ArtCandidate(${p.basename(file.path)}, $role, score $score)';
}

/// Finds artwork stored as separate files alongside music.
///
/// Embedded tag pictures are handled by the tag reader; this covers the other
/// half, which is how most well-organised collections actually store covers.
///
/// The naming conventions recognised here were taken from a real library
/// rather than invented, including the `<Name>_artist.jpg` form and the
/// `[Collection] <Artist>/` folder layout.
class ArtSidecarFinder {
  const ArtSidecarFinder();

  static const _imageExtensions = <String>{
    'jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif',
  };

  /// Extensions that look like images but are icons, not artwork.
  static const _iconExtensions = <String>{'ico', 'icns', 'cur'};

  /// Stems that conventionally mean "this is the album cover", best first.
  static const _coverStems = <String>[
    'cover',
    'folder',
    'front',
    'album',
    'albumart',
    'albumartsmall',
    'thumb',
  ];

  /// Stems that conventionally mean "this is the artist".
  static const _artistStems = <String>['artist', 'band', 'performer', 'poster'];

  static const _backStems = <String>['back', 'rear', 'cover_back', 'backcover'];

  static const _discStems = <String>['disc', 'cd', 'media', 'label'];

  /// Finds cover art for an audio file, searching its own directory.
  ///
  /// Returns candidates sorted best first. Empty when the folder holds no
  /// plausible artwork.
  List<ArtCandidate> forAudioFile(File audioFile) {
    final dir = audioFile.parent;
    final audioStem = p.basenameWithoutExtension(audioFile.path).toLowerCase();
    return _candidatesIn(dir, audioStem: audioStem);
  }

  /// Finds cover art for an album folder.
  List<ArtCandidate> forAlbumFolder(Directory dir) => _candidatesIn(dir);

  /// Finds an artist portrait for a folder that represents one artist.
  ///
  /// Real collections mark these as `artist.jpg` or `<Name>_artist.jpg`, often
  /// at the root of a `[Collection] <Artist>` directory.
  List<ArtCandidate> forArtistFolder(Directory dir) {
    final all = _candidatesIn(dir, preferArtist: true);
    return all.where((c) => c.role == ImageRole.artist).toList();
  }

  /// Strips a collection-folder prefix to recover the artist name.
  ///
  /// `[Collection] PinocchioP` becomes `PinocchioP`. Returns null when the
  /// folder name carries no such marker, because guessing an artist from an
  /// arbitrary folder name causes more harm than leaving it unset.
  static String? artistNameFromFolder(String folderName) {
    final match = RegExp(
      r'^\s*[\[\(](?:collection|artist|discography)[\]\)]\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(folderName);
    final name = match?.group(1)?.trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  List<ArtCandidate> _candidatesIn(
    Directory dir, {
    String? audioStem,
    bool preferArtist = false,
  }) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return const [];
    }

    final candidates = <ArtCandidate>[];
    for (final entity in entries) {
      if (entity is! File) continue;
      final extension =
          p.extension(entity.path).toLowerCase().replaceFirst('.', '');
      if (_iconExtensions.contains(extension)) continue;
      if (!_imageExtensions.contains(extension)) continue;

      final info = ImageProbe.probeFile(entity);
      if (info == null) continue;

      final stem = p.basenameWithoutExtension(entity.path).toLowerCase();
      final scored = _score(
        stem: stem,
        audioStem: audioStem,
        info: info,
        preferArtist: preferArtist,
      );
      if (scored == null) continue;

      candidates.add(ArtCandidate(
        file: entity,
        role: scored.role,
        score: scored.score,
        reason: scored.reason,
        info: info,
      ));
    }

    candidates.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      // Prefer the larger image when the names are equally convincing.
      return (b.info.width * b.info.height)
          .compareTo(a.info.width * a.info.height);
    });
    return candidates;
  }

  _Scored? _score({
    required String stem,
    required String? audioStem,
    required ImageInfo info,
    required bool preferArtist,
  }) {
    // An exact stem match with the audio file is a per-track image and beats
    // every folder-level convention.
    if (audioStem != null && stem == audioStem) {
      return _Scored(ImageRole.front, 1000, 'matches the audio file name');
    }

    for (final needle in _artistStems) {
      // Matches both "artist.jpg" and "PinocchioP_artist.jpg".
      if (stem == needle || stem.endsWith('_$needle') ||
          stem.endsWith(' $needle') || stem.endsWith('-$needle')) {
        return _Scored(
          ImageRole.artist,
          preferArtist ? 900 : 300,
          'named after the "$needle" convention',
        );
      }
    }

    for (final needle in _backStems) {
      if (stem == needle) {
        return _Scored(ImageRole.back, 200, 'named "$needle"');
      }
    }
    for (final needle in _discStems) {
      if (stem == needle) {
        return _Scored(ImageRole.disc, 200, 'named "$needle"');
      }
    }

    for (var i = 0; i < _coverStems.length; i++) {
      final needle = _coverStems[i];
      if (stem == needle) {
        return _Scored(
          ImageRole.front,
          800 - i * 10,
          'named "$needle"',
        );
      }
    }

    // Anything else is only artwork if it is big enough not to be an icon or a
    // stray screenshot thumbnail.
    if (!info.isPlausibleArtwork) return null;
    // Covers are square-ish; a wide banner in a music folder usually is not.
    final ratio = info.aspectRatio;
    if (ratio < 0.5 || ratio > 2.0) return null;

    return _Scored(
      ImageRole.other,
      100,
      'the only plausible image in the folder',
    );
  }
}

class _Scored {
  const _Scored(this.role, this.score, this.reason);
  final ImageRole role;
  final int score;
  final String reason;
}
