import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// Routes every uncaught error in the app into [AppLog].
///
/// Covers the four separate places Flutter can surface one, because an error
/// that reaches none of them is exactly the kind that produces a silent exit.
///
/// Flutter-only, unlike [AppLog] itself: this needs `FlutterError` and
/// `PlatformDispatcher`, which pull in `dart:ui` and so cannot be resolved by
/// the plain `dart run` the indexer's command-line tools are used with.
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
