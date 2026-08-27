import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import '../db/enums.dart';
import '../fs/vorbis_comments.dart';
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
    final extension = p.extension(file.path).toLowerCase().replaceFirst('.', '');

    // Typed as Object? because the package does not export the sealed base
    // type of its metadata models.
    final Object? tag;
    try {
      tag = readAllMetadata(file, getImage: includePictures);
    } catch (e) {
      // The package is strict about numeric fields and throws on values that
      // are perfectly legal in the wild - a vinyl release with `DISCNUMBER=A`
      // takes down the whole file, and the track then vanishes from the
      // library entirely. For FLAC the comment block can be read directly, so
      // recover rather than lose the track. Measured on a real library: 46
      // files rescued from one soundtrack folder.
      final recovered = _recoverFlac(file, extension);
      if (recovered != null) return recovered;
      rethrow;
    }

    return switch (tag) {
      Mp3Metadata m => _fromMp3(m, extension),
      // FLAC text fields are re-read from the raw comment block; see
      // _fromVorbis for why.
      VorbisMetadata m => _fromVorbis(
          m,
          extension,
          comments: extension == 'flac' ? FlacVorbisReader.read(file) : null,
        ),
      RiffMetadata m => _fromRiff(m, extension),
      ApeMetadata m => _fromApe(m, extension),
      Mp4Metadata m => _fromMp4(m, extension),
      _ => throw MetadataParserException(
          track: file,
          message: 'unrecognised metadata model ${tag.runtimeType}',
        ),
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

  /// Builds metadata for a FLAC the package could not parse.
  ///
  /// Returns null when this is not a FLAC, or when even the raw blocks are
  /// unreadable - at which point the file really is broken and the caller
  /// should report it.
  TrackFileMetadata? _recoverFlac(File file, String extension) {
    if (extension != 'flac') return null;
    final comments = FlacVorbisReader.read(file);
    final stream = FlacVorbisReader.readStreamInfo(file);
    if (comments == null && stream == null) return null;

    final credits = <RawCredit>[];
    final mains = _cleanList(comments?.all(const ['ARTIST']) ?? const []);
    final albumArtist = _clean(comments
        ?.first(const ['ALBUMARTIST', 'ALBUM ARTIST', 'ALBUM_ARTIST']));

    // Same guard as the normal path: an album-artist value repeated in ARTIST
    // is not a second track artist.
    final albumArtistLower = albumArtist?.toLowerCase();
    final filtered = mains.length > 1 && albumArtistLower != null
        ? mains.where((v) => v.toLowerCase() != albumArtistLower).toList()
        : mains;
    final effective = filtered.isEmpty ? mains : filtered;

    final preSplit = effective.length > 1;
    for (final value in effective) {
      credits.add(RawCredit(
        value: value,
        role: CreditRole.mainArtist,
        isPreSplit: preSplit,
      ));
    }
    for (final value in _cleanList(comments?.all(const ['COMPOSER']) ?? const [])) {
      credits.add(RawCredit(value: value, role: CreditRole.composer));
    }

    final date = _parseDateParts(comments?.first(const ['DATE', 'YEAR']));

    return TrackFileMetadata(
      title: _clean(comments?.first(const ['TITLE'])),
      albumTitle: _clean(comments?.first(const ['ALBUM'])),
      albumArtistRaw: albumArtist,
      credits: credits,
      // Deliberately lenient: a non-numeric disc or track label is exactly
      // what got us here, so it is dropped rather than allowed to fail again.
      trackNo: _parseIntOr(comments?.first(const ['TRACKNUMBER']), null),
      trackTotal:
          _parseIntOr(comments?.first(const ['TRACKTOTAL', 'TOTALTRACKS']), null),
      discNo: _parseIntOr(comments?.first(const ['DISCNUMBER']), null),
      discTotal:
          _parseIntOr(comments?.first(const ['DISCTOTAL', 'TOTALDISCS']), null),
      year: date?.year,
      month: date?.month,
      day: date?.day,
      genres: _cleanList(comments?.all(const ['GENRE']) ?? const []),
      languages: _cleanList(comments?.all(const ['LANGUAGE', 'LANG']) ?? const []),
      comment: _clean(comments?.first(const ['COMMENT', 'DESCRIPTION'])),
      lyrics: _clean(comments?.first(const ['LYRICS', 'UNSYNCEDLYRICS'])),
      replayGainDb: _parseGain(comments?.first(const ['REPLAYGAIN_TRACK_GAIN'])),
      duration: stream?.duration,
      bitrate: stream?.bitrate,
      sampleRate: stream?.sampleRate,
      channels: stream?.channels,
      bitDepth: stream?.bitsPerSample,
      lossless: true,
      codec: 'flac',
      // Pictures are skipped on this path: the package's picture reader is
      // what could not be trusted, and a missing cover is recoverable while a
      // missing track is not.
      pictures: const [],
      tagFormat: 'Vorbis comment (recovered)',
    );
  }

  // ------------------------------------------------------- Vorbis / FLAC, OGG

  /// Maps Vorbis comments, preferring the raw block when one could be read.
  ///
  /// The package's parser folds `ALBUMARTIST` into the same list as `ARTIST`.
  /// That has two consequences the credits model cannot live with: the album
  /// artist becomes unreadable, and "one artist plus an album artist" looks
  /// exactly like "genuinely two artists". Since repeated `ARTIST` fields are
  /// the most reliable multi-artist signal a file can carry - the file stating
  /// the answer outright, no heuristics needed - the text fields are re-read
  /// from the block itself. Stream properties and pictures still come from the
  /// package, which handles them well.
  TrackFileMetadata _fromVorbis(
    VorbisMetadata m,
    String extension, {
    VorbisCommentBlock? comments,
  }) {
    final credits = <RawCredit>[];

    final List<String> mains;
    final String? albumArtist;
    final List<String> genres;
    final List<String> languages;
    final String? rawDate;

    if (comments != null) {
      mains = _cleanList(comments.all(const ['ARTIST']));
      albumArtist = _clean(comments
          .first(const ['ALBUMARTIST', 'ALBUM ARTIST', 'ALBUM_ARTIST']));
      genres = _cleanList(comments.all(const ['GENRE']));
      languages = _cleanList(comments.all(const ['LANGUAGE', 'LANG']));
      rawDate = comments.first(const ['DATE', 'ORIGINALDATE', 'YEAR']);
    } else {
      mains = _cleanList(m.artist);
      albumArtist =
          _clean(_unknown(m.unknowns, const ['ALBUMARTIST', 'ALBUM ARTIST']));
      genres = _cleanList(m.genres);
      languages = _cleanList(m.language);
      rawDate = _unknown(m.unknowns, const ['DATE', 'ORIGINALDATE']);
    }

    // Guard against the conflation above even on the raw path, since a file may
    // legitimately repeat the album artist in ARTIST. Only drop it when
    // something else remains to credit.
    final albumArtistLower = albumArtist?.toLowerCase();
    final withoutAlbumArtist = mains.length > 1 && albumArtistLower != null
        ? mains.where((v) => v.toLowerCase() != albumArtistLower).toList()
        : mains;
    final effectiveMains =
        withoutAlbumArtist.isEmpty ? mains : withoutAlbumArtist;

    final preSplit = effectiveMains.length > 1;
    for (final value in effectiveMains) {
      credits.add(RawCredit(
        value: value,
        role: CreditRole.mainArtist,
        isPreSplit: preSplit,
      ));
    }

    void addAll(List<String> values, CreditRole role) {
      for (final value in _cleanList(values)) {
        credits.add(RawCredit(value: value, role: role));
      }
    }

    if (comments != null) {
      addAll(comments.all(const ['COMPOSER']), CreditRole.composer);
      addAll(comments.all(const ['PRODUCER']), CreditRole.producer);
      // PERFORMER is a supporting credit, not a lead.
      addAll(comments.all(const ['PERFORMER']), CreditRole.performer);
      addAll(comments.all(const ['LYRICIST']), CreditRole.lyricist);
      addAll(comments.all(const ['ARRANGER']), CreditRole.arranger);
      addAll(comments.all(const ['REMIXER', 'MIXARTIST']), CreditRole.remixer);
      addAll(comments.all(const ['CONDUCTOR']), CreditRole.conductor);
    } else {
      addAll(m.composer, CreditRole.composer);
      addAll(m.producer, CreditRole.producer);
      addAll(m.performer, CreditRole.performer);
      _addAll(credits, _unknown(m.unknowns, const ['LYRICIST']),
          CreditRole.lyricist);
      _addAll(credits, _unknown(m.unknowns, const ['ARRANGER']),
          CreditRole.arranger);
      _addAll(credits, _unknown(m.unknowns, const ['REMIXER', 'MIXARTIST']),
          CreditRole.remixer);
    }

    final date = _parseDateParts(rawDate) ??
        (m.date.isEmpty
            ? null
            : (year: m.date.first.year, month: null, day: null));

    String? fromEither(List<String> keys) => comments == null
        ? _unknown(m.unknowns, keys)
        : _clean(comments.first(keys));

    return TrackFileMetadata(
      title: _clean(comments?.first(const ['TITLE']) ?? m.title.firstOrNull),
      albumTitle:
          _clean(comments?.first(const ['ALBUM']) ?? m.album.firstOrNull),
      albumArtistRaw: albumArtist,
      credits: credits,
      trackNo: _parseIntOr(
          comments?.first(const ['TRACKNUMBER']), m.trackNumber.firstOrNull),
      trackTotal: _parseIntOr(
          comments?.first(const ['TRACKTOTAL', 'TOTALTRACKS']), m.trackTotal),
      discNo: _parseIntOr(comments?.first(const ['DISCNUMBER']), m.discNumber),
      discTotal: _parseIntOr(
          comments?.first(const ['DISCTOTAL', 'TOTALDISCS']), m.discTotal),
      year: date?.year,
      month: date?.month,
      day: date?.day,
      genres: genres,
      languages: languages,
      comment: _clean(comments?.first(const ['COMMENT', 'DESCRIPTION']) ??
          m.comment.firstOrNull),
      bpm: _toDouble(fromEither(const ['BPM'])),
      initialKey: _clean(fromEither(const ['INITIALKEY', 'KEY'])),
      lyrics: _clean(
          comments?.first(const ['LYRICS', 'UNSYNCEDLYRICS']) ?? m.lyric),
      rating: _parseRating(fromEither(const ['RATING'])),
      replayGainDb: _parseGain(
          comments?.first(const ['REPLAYGAIN_TRACK_GAIN']) ??
              m.replayGainTrackGain.firstOrNull),
      replayGainPeak: _toDouble(
          comments?.first(const ['REPLAYGAIN_TRACK_PEAK']) ??
              m.replayGainTrackPeak.firstOrNull),
      duration: m.duration,
      bitrate: m.bitrate,
      sampleRate: m.sampleRate,
      lossless: extension == 'flac',
      codec: extension,
      isCompilation: _isTruthy(fromEither(const ['COMPILATION'])),
      pictures: _pictures(m.pictures),
      tagFormat: comments == null ? 'Vorbis comment' : 'Vorbis comment (raw)',
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

  /// Parses a Vorbis DATE, keeping only the precision the tag actually stated.
  ///
  /// A year-only tag must not become 1 January: the file never claimed a day,
  /// and pretending otherwise would show a made-up release date.
  static ({int? year, int? month, int? day})? _parseDateParts(String? raw) {
    final text = _clean(raw);
    if (text == null) return null;
    final match = RegExp(r'^(\d{4})(?:[-/](\d{1,2}))?(?:[-/](\d{1,2}))?')
        .firstMatch(text);
    if (match == null) return null;
    return (
      year: int.tryParse(match.group(1)!),
      month: match.group(2) == null ? null : int.tryParse(match.group(2)!),
      day: match.group(3) == null ? null : int.tryParse(match.group(3)!),
    );
  }

  /// Prefers a raw tag value, falling back to the parser's own.
  static int? _parseIntOr(String? raw, int? fallback) {
    final text = _clean(raw);
    if (text == null) return fallback;
    // "3/12"-style values turn up here too.
    final match = RegExp(r'\d+').firstMatch(text);
    return match == null ? fallback : int.tryParse(match.group(0)!) ?? fallback;
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
