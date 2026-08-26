/// Duration formatting shared by every surface that shows a time.
library;

/// Formats a duration as `m:ss`, or `h:mm:ss` past an hour.
///
/// Never shows a leading zero on the first unit, and always pads the rest, so
/// times line up in a column when rendered with tabular figures.
String formatDuration(Duration duration) {
  if (duration.isNegative) return '0:00';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  final paddedSeconds = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$paddedSeconds';
  }
  return '$minutes:$paddedSeconds';
}

/// Formats a duration as prose, for summaries: "3 hr 12 min", "45 min".
String formatDurationLong(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) {
    return minutes == 0 ? '$hours hr' : '$hours hr $minutes min';
  }
  if (minutes > 0) return '$minutes min';
  return '${duration.inSeconds} sec';
}

/// Formats a count with its noun, pluralised: "1 track", "12 tracks".
String pluralize(int count, String singular, [String? plural]) =>
    '$count ${count == 1 ? singular : (plural ?? '${singular}s')}';
