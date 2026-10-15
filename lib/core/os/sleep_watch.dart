import 'dart:async';

import '../logging/app_log.dart';

/// Notices that the machine was asleep, and says so in the log.
///
/// Windows does not hand a Flutter app a resume event, and this app runs for
/// days at a time, so a sleep is otherwise invisible: the log simply has a
/// gap, and a gap is equally well explained by nobody touching the app. That
/// ambiguity is not academic -- an app hang that only ever showed up after a
/// long sleep had to be correlated by eye against gaps between unrelated
/// playback lines, with no way to tell a sleep from a lunch break.
///
/// Detected by watching the wall clock rather than by asking the OS: a
/// periodic timer that finds far more time has passed than it asked to wait
/// was, by definition, not running, which is what being suspended looks like
/// from inside the process.
class SleepWatch {
  SleepWatch({
    this.interval = const Duration(seconds: 30),
    this.onResume,
  });

  /// How often to check. Also the resolution of the gap that can be reported.
  final Duration interval;

  /// Called once per detected resume, after it is logged.
  ///
  /// The hook exists for whatever has to be put back together after a
  /// suspend; nothing uses it yet, and it deliberately does not assume the
  /// audio device is among them.
  final void Function(Duration sleptFor)? onResume;

  /// How far past [interval] a tick has to land to count as a suspend rather
  /// than an ordinary late timer.
  ///
  /// A loaded machine can run a 30-second timer several seconds late without
  /// having slept at all, so the threshold is a multiple, not a margin.
  static const _slack = 4;

  Timer? _timer;
  DateTime _last = DateTime.now();

  void start() {
    _last = DateTime.now();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    final now = DateTime.now();
    final elapsed = now.difference(_last);
    _last = now;
    if (elapsed <= interval * _slack) return;

    AppLog.instance.info(
      'resumed after the machine was suspended',
      tag: 'system',
      fields: {
        'awayFor': _spell(elapsed),
        'since': _last.subtract(elapsed).toIso8601String(),
      },
    );
    onResume?.call(elapsed);
  }

  /// Minutes are the useful unit here -- a suspend is never seconds, and
  /// "7523s" is arithmetic the reader should not have to do while comparing
  /// a resume against a hang.
  static String _spell(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }
}
