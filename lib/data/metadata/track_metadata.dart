import 'dart:typed_data';

import '../db/enums.dart';

/// One credit string exactly as a file spelled it, with the role it was found
/// under.
///
/// [isPreSplit] is the important flag. Some formats express several artists
/// properly - FLAC repeats the `ARTIST` field, ID3v2.4 separates values with a
/// null byte, Picard writes a `TXXX:ARTISTS` frame. When a file already told us
/// there are three artists, there is nothing to guess and the credit resolver
/// must not try: heuristics can only make well-tagged files worse.
class RawCredit {
  const RawCredit({
    required this.value,
    required this.role,
    this.isPreSplit = false,
  });

  /// The credit text, untouched.
  final String value;

  final CreditRole role;

  /// Whether this value came from a genuinely multi-valued tag field, and so
  /// needs no separator analysis.
  final bool isPreSplit;

  @override
  String toString() =>
      'RawCredit("$value", $role${isPreSplit ? ", pre-split" : ""})';
}

/// An image found inside an audio file.
class EmbeddedPicture {
  const EmbeddedPicture({
    required this.bytes,
    required this.mimeType,
    required this.role,
  });

  final Uint8List bytes;
  final String mimeType;
  final ImageRole role;
}

/// Everything the app reads out of one audio file.
///
/// Deliberately a flat, format-independent snapshot. Every format-specific
/// quirk is resolved in [TagReader] so nothing downstream needs to know
/// whether it is looking at ID3, Vorbis comments or RIFF chunks.
class TrackFileMetadata {
  TrackFileMetadata({
    this.title,
    this.albumTitle,
    this.albumArtistRaw,
    this.credits = const [],
    this.trackNo,
    this.trackTotal,
    this.discNo,
    this.discTotal,
    this.year,
    this.month,
    this.day,
    this.genres = const [],
    this.languages = const [],
    this.comment,
    this.bpm,
    this.initialKey,
    this.lyrics,
    this.rating,
    this.replayGainDb,
    this.replayGainPeak,
    this.duration,
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.bitDepth,
    this.lossless = false,
    this.codec,
    this.isCompilation = false,
    this.pictures = const [],
    this.tagFormat,
  });

  final String? title;
  final String? albumTitle;

  /// The album-artist string, kept separate from [credits] because it
  /// describes the release, not this track.
  final String? albumArtistRaw;

  /// Every artist credit found, in tag order.
  final List<RawCredit> credits;

  final int? trackNo;
  final int? trackTotal;
  final int? discNo;
  final int? discTotal;

  final int? year;
  final int? month;
  final int? day;

  final List<String> genres;

  /// Language codes or names, destined for the Language tag category.
  final List<String> languages;

  final String? comment;
  final double? bpm;
  final String? initialKey;
  final String? lyrics;

  /// 0-100, converted from whatever scale the format used.
  final int? rating;

  final double? replayGainDb;
  final double? replayGainPeak;

  final Duration? duration;
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
  final int? bitDepth;
  final bool lossless;
  final String? codec;

  final bool isCompilation;
  final List<EmbeddedPicture> pictures;

  /// Which tag container this came from, for the debug view.
  final String? tagFormat;

  /// Credits carrying [CreditRole.mainArtist].
  Iterable<RawCredit> get mainCredits =>
      credits.where((c) => c.role == CreditRole.mainArtist);

  /// Whether the file gave us nothing worth indexing beyond audio properties.
  bool get isEffectivelyUntagged =>
      (title == null || title!.trim().isEmpty) && credits.isEmpty;

  @override
  String toString() => 'TrackFileMetadata(title: $title, album: $albumTitle, '
      'credits: $credits, format: $tagFormat)';
}
