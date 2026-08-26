import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import '../db/enums.dart';
import 'track_metadata.dart';

/// Audio file extensions the library indexes.
///
/// Kept deliberately narrow. Anything else in a watched folder - artwork,
/// booklets, stray `.download` files, saved web pages - is ignored rather than
/// recorded as a broken track.
const supportedAudioExtensions = <String>{'mp3', 'flac', 'wav'};

/// Extensions the reader can parse but the app does not currently index.
///
/// Listed so the scanner can report "found 12 m4a files, not indexed" instead
/// of silently ignoring them.
const parseableButUnindexedExtensions = <String>{
  'm4a', 'mp4', 'aac', 'ogg', 'opus', 'aiff', 'aif', 'ape', 'wv',
};

/// Reads audio files into a format-independent [TrackFileMetadata].
///
/// Uses `readAllMetadata`, which returns the raw format-specific frames, and
/// maps them here. The package's own `readMetadata` convenience wrapper is
/// deliberately avoided: for MP3 it resolves `artist` as `TPE2 ?? TPE1`, so the
/// album artist shadows the track artist, and for FLAC it keeps only
/// `artist.firstOrNull`, discarding the multi-value `ARTIST` fields that are
/// the single most reliable multi-artist signal a file can carry.
class TagReader {
  const TagReader();

  /// The NUL byte ID3v2.4 and Vorbis comments use to pack several values into
  /// a single field. Written by code point: a literal NUL in source is
  /// invisible and does not survive editors, shells or diffs intact.
  static final String _nul = String.fromCharCode(0);
  static final String _byteOrderMark = String.fromCharCode(0xFEFF);
  static final String _nonBreakingSpace = String.fromCharCode(0xA0);

  /// Reads [file], or throws [MetadataParserException] if it cannot be parsed.
  ///
  /// [includePictures] is off by default because embedded covers are routinely
  /// several megabytes and a scan touches thousands of files.
  TrackFileMetadata read(File file, {bool includePictures = false}) {
    final tag = readAllMetadata(file, getImage: includePictures);
    final extension = p.extension(file.path).toLowerCase().replaceFirst('.', '');

    return switch (tag) {
      Mp3Metadata m => _fromMp3(m, extension),
      VorbisMetadata m => _fromVorbis(m, extension),
      RiffMetadata m => _fromRiff(m, extension),
      ApeMetadata m => _fromApe(m, extension),
      Mp4Metadata m => _fromMp4(m, extension),
    };
  }

  /// Reads [file], returning null instead of throwing.
  TrackFileMetadata? tryRead(File file, {bool includePictures = false}) {
    try {
      return read(file, includePictures: includePictures);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- ID3 / MP3

  TrackFileMetadata _fromMp3(Mp3Metadata m, String extension) {
    final credits = <RawCredit>[];

    // Picard and friends write a TXXX:ARTISTS frame holding every artist
    // separately. When present it is authoritative and needs no splitting.
    final artistsFrame = _custom(m.customMetadata, const ['ARTISTS', 'ARTIST']);
    final preSplitMains = artistsFrame == null
        ? const <String>[]
        : _splitMultiValue(artistsFrame);

    if (preSplitMains.length > 1) {
      credits.addAll(preSplitMains.map((v) => RawCredit(
            value: v,
            role: CreditRole.mainArtist,
            isPreSplit: true,
          )));
    } else {
      // TPE1 is the track artist. ID3v2.4 separates multiple values with a
      // null byte, which is a genuine multi-value signal.
      _addAll(credits, m.leadPerformer, CreditRole.mainArtist);
    }

    _addAll(credits, m.composer, CreditRole.composer);
    _addAll(credits, m.textWriter, CreditRole.lyricist);
    _addAll(credits, m.conductor, CreditRole.conductor);
    _addAll(credits, m.interpreted, CreditRole.remixer);
    _addAll(credits, m.originalArtist, CreditRole.originalArtist);
    _addAll(credits,
        _custom(m.customMetadata, const ['ARRANGER']), CreditRole.arranger);
    _addAll(credits,
        _custom(m.customMetadata, const ['PRODUCER']), CreditRole.producer);

    // TPE2 is the band/album artist. Prefer an explicit TXXX:ALBUMARTIST when
    // one exists, since taggers disagree about what TPE2 means.
    final albumArtist =
        _custom(m.customMetadata, const ['ALBUMARTIST', 'ALBUM ARTIST']) ??
            m.bandOrOrchestra;

    final languages = <String>[
      ...?_nonEmpty(m.languages)?.let(_splitMultiValue),
      ...?_custom(m.customMetadata, const ['LANGUAGE', 'LANG'])
          ?.let(_splitMultiValue),
    ];

    return TrackFileMetadata(
      title: _clean(m.songName),
      albumTitle: _clean(m.album),
      albumArtistRaw: _clean(albumArtist),
      credits: credits,
      trackNo: m.trackNumber,
      trackTotal: m.trackTotal,
      discNo: m.discNumber ?? _leadingInt(m.partOfSet),
      discTotal: m.totalDics ?? _trailingInt(m.partOfSet),
      year: m.year ?? m.originalReleaseYear,
      genres: _cleanList(m.genres),
      languages: _cleanList(languages),
      comment: _clean(m.comments.isEmpty ? null : m.comments.first.text),
      bpm: _toDouble(m.bpm),
      initialKey: _clean(m.initialKey),
      lyrics: _clean(m.lyric),
      // POPM stores 0-255. Convert to the app's 0-100 scale.
      rating: m.popularimeter == null
          ? null
          : (m.popularimeter!.rating * 100 / 255).round(),
      replayGainDb: _parseGain(
          _custom(m.customMetadata, const ['REPLAYGAIN_TRACK_GAIN'])),
      replayGainPeak: _toDouble(
          _custom(m.customMetadata, const ['REPLAYGAIN_TRACK_PEAK'])),
      duration: m.duration,
      bitrate: m.bitrate,
      sampleRate: m.samplerate,
      lossless: false,
      codec: 'mp3',
      isCompilation:
          _isTruthy(_custom(m.customMetadata, const ['COMPILATION'])),
      pictures: _pictures(m.pictures),
      tagFormat: 'ID3',
    );
  }

  // ------------------------------------------------------- Vorbis / FLAC, OGG

  TrackFileMetadata _fromVorbis(VorbisMetadata m, String extension) {
    final credits = <RawCredit>[];

    // Vorbis comments may legitimately repeat ARTIST. Several values means the
    // file already answered the question.
    final mains = _cleanList(m.artist);
    final preSplit = mains.length > 1;
    for (final value in mains) {
      credits.add(RawCredit(
        value: value,
        role: CreditRole.mainArtist,
        isPreSplit: preSplit,
      ));
    }

    for (final value in _cleanList(m.composer)) {
      credits.add(RawCredit(value: value, role: CreditRole.composer));
    }
    for (final value in _cleanList(m.producer)) {
      credits.add(RawCredit(value: value, role: CreditRole.producer));
    }
    // PERFORMER is a supporting credit, not a lead.
    for (final value in _cleanList(m.performer)) {
      credits.add(RawCredit(value: value, role: CreditRole.performer));
    }
    _addAll(credits, _unknown(m.unknowns, const ['LYRICIST']),
        CreditRole.lyricist);
    _addAll(credits, _unknown(m.unknowns, const ['ARRANGER']),
        CreditRole.arranger);
    _addAll(credits, _unknown(m.unknowns, const ['REMIXER', 'MIXARTIST']),
        CreditRole.remixer);

    final date = m.date.isEmpty ? null : m.date.first;

    return TrackFileMetadata(
      title: _clean(m.title.firstOrNull),
      albumTitle: _clean(m.album.firstOrNull),
      albumArtistRaw: _clean(
          _unknown(m.unknowns, const ['ALBUMARTIST', 'ALBUM ARTIST'])),
      credits: credits,
      trackNo: m.trackNumber.firstOrNull,
      trackTotal: m.trackTotal,
      discNo: m.discNumber,
      discTotal: m.discTotal,
      // Vorbis DATE is a real date, but a year-only tag parses as 1 January.
      // Month and day are only trusted when the tag actually carried them.
      year: date?.year,
      month: _hasFullDate(m.unknowns, m.date) ? date?.month : null,
      day: _hasFullDate(m.unknowns, m.date) ? date?.day : null,
      genres: _cleanList(m.genres),
      languages: _cleanList(m.language),
      comment: _clean(m.comment.firstOrNull),
      bpm: _toDouble(_unknown(m.unknowns, const ['BPM'])),
      initialKey: _clean(_unknown(m.unknowns, const ['INITIALKEY', 'KEY'])),
      lyrics: _clean(m.lyric),
      rating: _parseRating(_unknown(m.unknowns, const ['RATING'])),
      replayGainDb: _parseGain(m.replayGainTrackGain.firstOrNull),
      replayGainPeak: _toDouble(m.replayGainTrackPeak.firstOrNull),
      duration: m.duration,
      bitrate: m.bitrate,
      sampleRate: m.sampleRate,
      lossless: extension == 'flac',
      codec: extension,
      isCompilation: _isTruthy(_unknown(m.unknowns, const ['COMPILATION'])),
      pictures: _pictures(m.pictures),
      tagFormat: 'Vorbis comment',
    );
  }

  // ------------------------------------------------------------- RIFF / WAV

  TrackFileMetadata _fromRiff(RiffMetadata m, String extension) {
    final credits = <RawCredit>[];
    _addAll(credits, m.artist, CreditRole.mainArtist);

    return TrackFileMetadata(
      title: _clean(m.title),
      albumTitle: _clean(m.album),
      credits: credits,
      trackNo: m.trackNumber,
      year: m.year?.year,
      genres: _cleanList([m.genre]),
      comment: _clean(m.comment),
      duration: m.duration,
      bitrate: m.bitrate,
      sampleRate: m.samplerate,
      lossless: true,
      codec: extension,
      pictures: _pictures(m.pictures),
      tagFormat: 'RIFF INFO',
    );
  }

  // ------------------------------------------------------------------- APEv2

  TrackFileMetadata _fromApe(ApeMetadata m, String extension) {
    final credits = <RawCredit>[];
    _addAll(credits, m.artist, CreditRole.mainArtist);
    _addAll(credits, m.composer, CreditRole.composer);
    for (final value in _cleanList(m.performer)) {
      credits.add(RawCredit(value: value, role: CreditRole.performer));
    }

    return TrackFileMetadata(
      title: _clean(m.title),
      albumTitle: _clean(m.album),
      albumArtistRaw: _clean(m.albumArtist),
      credits: credits,
      trackNo: m.trackNumber,
      trackTotal: m.trackTotal,
      discNo: m.discNumber,
      discTotal: m.discTotal,
      year: m.date?.year,
      genres: _cleanList(m.genres),
      languages: _cleanList(m.language),
      comment: _clean(m.comment),
      lyrics: _clean(m.lyric),
      duration: m.duration,
      bitrate: m.bitrate,
      sampleRate: m.sampleRate,
      codec: extension,
      pictures: _pictures(m.pictures),
      tagFormat: 'APEv2',
    );
  }

  // -------------------------------------------------------------------- MP4

  TrackFileMetadata _fromMp4(Mp4Metadata m, String extension) {
    final credits = <RawCredit>[];
    _addAll(credits, m.artist, CreditRole.mainArtist);

    return TrackFileMetadata(
      title: _clean(m.title),
      albumTitle: _clean(m.album),
      credits: credits,
      trackNo: m.trackNumber,
      trackTotal: m.totalTracks,
      discNo: m.discNumber,
      discTotal: m.totalDiscs,
      year: m.year?.year,
      genres: _cleanList([m.genre]),
      lyrics: _clean(m.lyrics),
      duration: m.duration,
      bitrate: m.bitrate,
      sampleRate: m.sampleRate,
      codec: extension,
      pictures: _pictures(m.picture == null ? const [] : [m.picture!]),
      tagFormat: 'MP4 atoms',
    );
  }

  // ------------------------------------------------------------------ helpers

  /// Adds [value] as one or more credits, splitting genuine multi-value
  /// encodings but leaving separator analysis to the resolver.
  void _addAll(List<RawCredit> into, String? value, CreditRole role) {
    final cleaned = _clean(value);
    if (cleaned == null) return;
    final parts = _splitMultiValue(cleaned);
    final preSplit = parts.length > 1;
    for (final part in parts) {
      into.add(RawCredit(value: part, role: role, isPreSplit: preSplit));
    }
  }

  /// Splits on the null byte that ID3v2.4 and Vorbis use to pack several
  /// values into one field.
  ///
  /// Only these formal separators are honoured here. Textual separators such
  /// as " x " are the resolver's business, because acting on them needs
  /// knowledge of the library.
  static List<String> _splitMultiValue(String value) {
    final parts = value
        .split(_nul)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? const [] : parts;
  }

  static String? _clean(String? value) {
    if (value == null) return null;
    // Taggers leave NUL padding, byte-order marks and non-breaking spaces
    // behind. None of it is content.
    final trimmed = value
        .replaceAll(_nul, ' ')
        .replaceAll(_byteOrderMark, '')
        .replaceAll(_nonBreakingSpace, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<String> _cleanList(Iterable<String?> values) {
    final out = <String>[];
    for (final value in values) {
      final cleaned = _clean(value);
      if (cleaned == null) continue;
      for (final part in _splitMultiValue(cleaned)) {
        if (!out.contains(part)) out.add(part);
      }
    }
    return out;
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value;

  /// Case-insensitive lookup across a map of custom tag frames.
  static String? _custom(Map<String, String> map, List<String> keys) {
    if (map.isEmpty) return null;
    for (final key in keys) {
      for (final entry in map.entries) {
        if (entry.key.toUpperCase() == key.toUpperCase()) {
          return _nonEmpty(entry.value);
        }
      }
    }
    return null;
  }

  static String? _unknown(Map<String, String> map, List<String> keys) =>
      _custom(map, keys);

  /// Whether a Vorbis DATE tag carried more than just a year.
  ///
  /// The parser turns "2023" into 2023-01-01, which would otherwise be
  /// recorded as a precise release date that the file never claimed.
  static bool _hasFullDate(Map<String, String> unknowns, List<DateTime> dates) {
    if (dates.isEmpty) return false;
    final raw = _custom(unknowns, const ['DATE', 'ORIGINALDATE']);
    if (raw == null) {
      // No raw form available; only trust a date that is not 1 January.
      return !(dates.first.month == 1 && dates.first.day == 1);
    }
    return raw.contains('-') || raw.contains('/');
  }

  static double? _toDouble(String? value) =>
      value == null ? null : double.tryParse(value.trim());

  /// Parses a ReplayGain value such as "-7.32 dB".
  static double? _parseGain(String? value) {
    if (value == null) return null;
    final match = RegExp(r'-?\d+(\.\d+)?').firstMatch(value);
    return match == null ? null : double.tryParse(match.group(0)!);
  }

  /// Normalises the several rating conventions onto 0-100.
  static int? _parseRating(String? value) {
    final parsed = _toDouble(value);
    if (parsed == null) return null;
    // 0-5 stars, 0-10, 0-100 and 0-255 are all in the wild. Guess by range.
    if (parsed <= 5) return (parsed * 20).round();
    if (parsed <= 10) return (parsed * 10).round();
    if (parsed <= 100) return parsed.round();
    return (parsed * 100 / 255).round();
  }

  static bool _isTruthy(String? value) {
    if (value == null) return false;
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }

  /// First integer in a "3/12"-style field.
  static int? _leadingInt(String? value) {
    if (value == null) return null;
    final match = RegExp(r'\d+').firstMatch(value);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  /// Second integer in a "3/12"-style field.
  static int? _trailingInt(String? value) {
    if (value == null) return null;
    final parts = value.split('/');
    if (parts.length < 2) return null;
    return _leadingInt(parts[1]);
  }

  static List<EmbeddedPicture> _pictures(List<Picture> pictures) => [
        for (final picture in pictures)
          EmbeddedPicture(
            bytes: picture.bytes,
            mimeType: picture.mimetype,
            role: _pictureRole(picture.pictureType),
          ),
      ];

  static ImageRole _pictureRole(PictureType type) => switch (type) {
        PictureType.coverFront => ImageRole.front,
        PictureType.coverBack => ImageRole.back,
        PictureType.mediaLabelCD => ImageRole.disc,
        PictureType.leafletPage => ImageRole.booklet,
        PictureType.leadArtist ||
        PictureType.artistPerformer ||
        PictureType.conductor ||
        PictureType.bandOrchestra ||
        PictureType.composer ||
        PictureType.lyricistTextWriter =>
          ImageRole.artist,
        PictureType.bandArtistLogotype ||
        PictureType.publisherStudioLogotype =>
          ImageRole.logo,
        _ => ImageRole.other,
      };
}

extension _Let<T> on T {
  /// Small helper so nullable chains stay readable.
  R let<R>(R Function(T) fn) => fn(this);
}
