import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/core/os/sleep_watch.dart';

/// Telling a suspend apart from a quiet afternoon.
///
/// The app is routinely left running for days, so a gap in the log has two
/// equally plausible readings and no way to choose between them. This picks
/// the right one by noticing that its own timer did not run.
void main() {
  test('says nothing while the timer keeps up', () async {
    var resumes = 0;
    final watch = SleepWatch(
      interval: const Duration(milliseconds: 10),
      onResume: (_) => resumes++,
    )..start();
    addTearDown(watch.stop);

    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(resumes, 0, reason: 'ticks landed on time, so nothing slept');
  });

  test('reports how long the machine was away', () async {
    // A suspend looks, from inside the process, exactly like a timer that
    // did not fire for a long time -- so that is what is simulated here, by
    // blocking the event loop past several intervals.
    Duration? slept;
    final watch = SleepWatch(
      interval: const Duration(milliseconds: 20),
      onResume: (d) => slept = d,
    )..start();
    addTearDown(watch.stop);

    final until = DateTime.now().add(const Duration(milliseconds: 250));
    while (DateTime.now().isBefore(until)) {
      // Deliberately synchronous: the timer cannot run, which is the point.
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(slept, isNotNull);
    expect(slept!.inMilliseconds, greaterThan(80),
        reason: 'four intervals is the threshold');
  });

  test('stops watching once stopped', () async {
    var resumes = 0;
    final watch = SleepWatch(
      interval: const Duration(milliseconds: 10),
      onResume: (_) => resumes++,
    )..start();
    watch.stop();

    final until = DateTime.now().add(const Duration(milliseconds: 120));
    while (DateTime.now().isBefore(until)) {}
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(resumes, 0);
  });
}
