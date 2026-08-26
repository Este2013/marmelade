import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Resolves where marmelade keeps its data on disk.
///
/// This is the only place in the app that touches `path_provider`. Keeping it
/// here rather than inside the data layer means the database, the indexer and
/// the artwork store are all plain Dart: they can be driven from command-line
/// tools and tested without a Flutter binding.
abstract final class StoragePaths {
  /// Root of the app's private data.
  static Future<Directory> appSupport() => getApplicationSupportDirectory();

  /// The library database.
  static Future<String> databaseFile() async =>
      p.join((await appSupport()).path, 'marmelade.db');

  /// The content-addressed artwork store.
  static Future<Directory> artworkDirectory() async =>
      Directory(p.join((await appSupport()).path, 'artwork'));

  /// Where lyrics files created by the app are kept.
  ///
  /// Lyrics linked from elsewhere on disk stay where they are; only documents
  /// the app itself creates live here.
  static Future<Directory> lyricsDirectory() async =>
      Directory(p.join((await appSupport()).path, 'lyrics'));

  /// Scratch space for downloads, such as an update package.
  static Future<Directory> downloadsDirectory() async =>
      Directory(p.join((await appSupport()).path, 'downloads'));

  /// Where crash and diagnostic logs are written.
  static Future<Directory> logsDirectory() async =>
      Directory(p.join((await appSupport()).path, 'logs'));
}
