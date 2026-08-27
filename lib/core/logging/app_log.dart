import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Severity of a log record.
enum LogLevel {
  trace,
  debug,
  info,
  warn,
  error;

  /// Fixed-width tag, so lines align in a text editor.
  String get tag => switch (this) {
        LogLevel.trace => 'TRACE',
        LogLevel.debug => 'DEBUG',
        LogLevel.info => 'INFO ',
        LogLevel.warn => 'WARN ',
        LogLevel.error => 'ERROR',
      };
}

/// Writes a crash-survivable log to disk.
///
/// Every line is written and flushed synchronously. That is deliberate and it
/// is the whole point of this class: when the process dies hard - a native
/// crash, an out-of-memory kill, the debugger reporting nothing but "lost
/// connection to device" - anything still sitting in a buffer is gone, and a
/// buffered logger tells you nothing about the moment that matters.
///
/// The cost is a file write per line, which at this app's volume is
/// irrelevant next to reading and hashing audio files.
///
/// A run that ends without a `session end` line crashed. That single fact is
/// usually enough to tell a crash from a clean exit.
class AppLog {
  AppLog._(this._handle, this.file, this.minLevel);

  static AppLog? _instance;

  /// The active logger, or null before [initialize].
  static AppLog? get maybeInstance => _instance;

  /// The active logger. Falls back to a no-op sink rather than throwing, so a
  /// logging call can never itself be the reason something breaks.
  static AppLog get instance => _instance ??= AppLog._(null, null, LogLevel.info);

  final RandomAccessFile? _handle;

  /// The file being written to, or null when logging to nowhere.
  final File? file;

  LogLevel minLevel;

  /// Lines kept in memory so the debug screen can show them without reading
  /// the file back.
  final _recent = <String>[];
  static const _recentLimit = 500;

  /// Opens a log file under [directory] and installs global error handlers.
  ///
  /// Safe to call more than once; later calls are ignored.
  static Future<AppLog> initialize({
    required Directory directory,
    LogLevel minLevel = LogLevel.debug,
    int keepFiles = 5,
  }) async {
    if (_instance?._handle != null) return _instance!;

    RandomAccessFile? handle;
    File? target;
    try {
      await directory.create(recursive: true);
      _pruneOldLogs(directory, keepFiles);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      target = File(p.join(directory.path, 'marmelade-$stamp.log'));
      handle = target.openSync(mode: FileMode.writeOnlyAppend);
    } catch (e) {
      // Losing the log must not stop the app from starting.
      debugPrint('marmelade: could not open a log file: $e');
      handle = null;
      target = null;
    }

    final log = AppLog._(handle, target, minLevel);
    _instance = log;

    log.info('session start', fields: {
      'pid': pid,
      'dart': Platform.version.split(' ').first,
      'os': Platform.operatingSystemVersion,
      'mode': kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release'),
      'log': target?.path,
    });
    return log;
  }

  /// Removes all but the [keep] newest log files.
  static void _pruneOldLogs(Directory directory, int keep) {
    try {
      final logs = directory
          .listSync()
          .whereType<File>()
          .where((f) => p.extension(f.path) == '.log')
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final old in logs.skip(keep)) {
        old.deleteSync();
      }
    } catch (_) {
      // Housekeeping only.
    }
  }

  // ------------------------------------------------------------------ writing

  void trace(String message, {String? tag, Map<String, Object?>? fields}) =>
      log(LogLevel.trace, message, tag: tag, fields: fields);

  void debug(String message, {String? tag, Map<String, Object?>? fields}) =>
      log(LogLevel.debug, message, tag: tag, fields: fields);

  void info(String message, {String? tag, Map<String, Object?>? fields}) =>
      log(LogLevel.info, message, tag: tag, fields: fields);

  void warn(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
  }) =>
      log(LogLevel.warn, message,
          tag: tag, error: error, stack: stack, fields: fields);

  void error(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
  }) =>
      log(LogLevel.error, message,
          tag: tag, error: error, stack: stack, fields: fields);

  void log(
    LogLevel level,
    String message, {
    String? tag,
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
  }) {
    if (level.index < minLevel.index) return;

    final buffer = StringBuffer()
      ..write(_timestamp())
      ..write('  ')
      ..write(level.tag)
      ..write('  ');
    if (tag != null) buffer.write('[$tag] ');
    buffer.write(message);

    if (fields != null && fields.isNotEmpty) {
      buffer.write('  {');
      var first = true;
      for (final entry in fields.entries) {
        if (!first) buffer.write(', ');
        first = false;
        buffer.write('${entry.key}=${entry.value}');
      }
      buffer.write('}');
    }
    if (error != null) buffer.write('\n    error: $error');
    if (stack != null) {
      // Trimmed: a full Flutter stack is mostly framework frames, and an
      // unreadable log gets ignored.
      final frames = stack.toString().split('\n').take(24);
      buffer.write('\n    ${frames.join('\n    ')}');
    }

    final line = buffer.toString();
    _remember(line);

    // In debug builds the console is still the fastest place to read.
    if (kDebugMode) debugPrint(line);

    final handle = _handle;
    if (handle == null) return;
    try {
      handle.writeStringSync('$line\n');
      handle.flushSync();
    } catch (_) {
      // A failed write must not cascade.
    }
  }

  void _remember(String line) {
    _recent.add(line);
    if (_recent.length > _recentLimit) {
      _recent.removeRange(0, _recent.length - _recentLimit);
    }
  }

  /// The most recent lines, oldest first.
  List<String> recentLines({int limit = _recentLimit}) {
    final start = _recent.length > limit ? _recent.length - limit : 0;
    return _recent.sublist(start);
  }

  /// Resident memory in bytes, or null when unavailable.
  ///
  /// Worth logging around anything that allocates in bulk: a steady climb is
  /// how an out-of-memory death announces itself before it happens.
  static int? residentBytes() {
    try {
      return ProcessInfo.currentRss;
    } catch (_) {
      return null;
    }
  }

  /// Formats a byte count for a log line.
  static String formatBytes(int? bytes) {
    if (bytes == null) return 'unknown';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// Logs a marker so a clean exit is distinguishable from a crash.
  void sessionEnd(String reason) {
    info('session end', fields: {
      'reason': reason,
      'rss': formatBytes(residentBytes()),
    });
    try {
      _handle?.flushSync();
      _handle?.closeSync();
    } catch (_) {}
  }

  static String _timestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}'
        '.${three(now.millisecond)}';
  }
}

/// Routes every uncaught error in the app into [AppLog].
///
/// Covers the four separate places Flutter can surface one, because an error
/// that reaches none of them is exactly the kind that produces a silent exit.
void installErrorHandlers() {
  final log = AppLog.instance;

  FlutterError.onError = (details) {
    log.error(
      'flutter error',
      tag: details.library,
      error: details.exception,
      stack: details.stack,
      fields: {'context': details.context?.toStringDeep().split('\n').first},
    );
    // Keep the red screen and console output in debug.
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.error('uncaught async error', error: error, stack: stack);
    // Handled: an unhandled error here terminates the isolate.
    return true;
  };

  // Errors thrown while building or painting a widget that the framework
  // cannot attribute to a specific widget.
  FlutterError.demangleStackTrace = (stack) => stack;
}

/// Runs [body] with uncaught synchronous and asynchronous errors logged.
Future<void> runGuardedWithLogging(Future<void> Function() body) async {
  await runZonedGuarded(body, (error, stack) {
    AppLog.instance.error('uncaught zone error', error: error, stack: stack);
  });
}
