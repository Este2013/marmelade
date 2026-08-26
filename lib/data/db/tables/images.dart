import 'package:drift/drift.dart';

import '../enums.dart';
import 'library.dart';

/// An artwork image, stored content-addressed.
///
/// The bytes live on disk under the app's image store at
/// `images/<sha256[0:2]>/<sha256>.<ext>`; only metadata is kept here. Because
/// the filename is the content hash, the same cover embedded in fifty tracks
/// is stored exactly once, and [sha256] is unique.
@TableIndex(name: 'idx_images_role', columns: {#role})
class Images extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Lower-case hex SHA-256 of the image bytes. The store's primary key.
  TextColumn get sha256 => text().unique()();

  TextColumn get kind => textEnum<ImageKind>()();
  TextColumn get role =>
      textEnum<ImageRole>().withDefault(const Constant('front'))();

  TextColumn get mimeType => text()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  IntColumn get byteSize => integer()();

  /// Path relative to the image store root.
  TextColumn get storedPath => text()();

  /// For [ImageKind.embedded]: the file the image was extracted from.
  IntColumn get sourceFileId => integer()
      .nullable()
      .references(MediaFiles, #id, onDelete: KeyAction.setNull)();

  /// For [ImageKind.sidecar]: the original path it was found at. Also used as
  /// a human-readable provenance note in the UI.
  TextColumn get sourceDescription => text().nullable()();

  /// Cached dominant colour as an ARGB int, so grids can tint placeholders
  /// before the full image decodes.
  IntColumn get dominantColor => integer().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
}
