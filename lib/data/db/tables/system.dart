import 'package:drift/drift.dart';

import '../enums.dart';
import 'catalog.dart';
import 'library.dart';

/// Application settings, as a typed key/value store.
///
/// Kept in the database rather than a preferences file so that settings, the
/// library and the debug tooling all read from one place, and so the database
/// explorer can show them.
class Settings extends Table {
  TextColumn get key => text()();

  /// Value encoded as JSON. [valueType] records what to decode it as.
  TextColumn get value => text()();

  /// One of `bool`, `int`, `double`, `string`, `json`.
  TextColumn get valueType => text()();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  Set<Column> get primaryKey => {key};
}

/// One library scan, recorded for the debug view and for "last scanned" UI.
@TableIndex(name: 'idx_scan_runs_started', columns: {#startedAt})
class ScanRuns extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Null when the run covered every folder.
  IntColumn get folderId => integer()
      .nullable()
      .references(LibraryFolders, #id, onDelete: KeyAction.cascade)();

  TextColumn get trigger => textEnum<ScanTrigger>()();
  TextColumn get status =>
      textEnum<ScanStatus>().withDefault(const Constant('running'))();

  DateTimeColumn get startedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get finishedAt => dateTime().nullable()();

  IntColumn get filesSeen => integer().withDefault(const Constant(0))();
  IntColumn get filesAdded => integer().withDefault(const Constant(0))();
  IntColumn get filesUpdated => integer().withDefault(const Constant(0))();

  /// Files recognised as the same content at a new path.
  IntColumn get filesMoved => integer().withDefault(const Constant(0))();

  IntColumn get filesMissing => integer().withDefault(const Constant(0))();
  IntColumn get errorCount => integer().withDefault(const Constant(0))();

  TextColumn get errorMessage => text().nullable()();
}

/// Something a scan could not resolve by itself.
///
/// These are the app's inbox: ambiguous credits, unreadable files, duplicate
/// content. Surfaced in settings so nothing fails silently.
@TableIndex(name: 'idx_scan_issues_kind', columns: {#kind})
@TableIndex(name: 'idx_scan_issues_unresolved', columns: {#resolvedAt})
class ScanIssues extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get scanRunId => integer()
      .nullable()
      .references(ScanRuns, #id, onDelete: KeyAction.setNull)();

  TextColumn get kind => textEnum<ScanIssueKind>()();

  /// Absolute path of the file involved, when there is one.
  TextColumn get filePath => text().nullable()();

  TextColumn get message => text()();

  /// JSON payload with whatever the resolver needs to offer a fix.
  TextColumn get detail => text().nullable()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
}

/// A token that splits a credit string into several artists.
///
/// Seeded with sensible defaults and fully editable, because no fixed list
/// survives contact with a real music collection. [requiresSpaces]
/// distinguishes `x` - which must appear as " x " so that "Maxence" survives -
/// from `,` which does not.
class SeparatorTokens extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The literal token, matched case-insensitively.
  TextColumn get token => text().unique()();

  TextColumn get kind =>
      textEnum<SeparatorKind>().withDefault(const Constant('split'))();

  /// When true, the token only counts as a separator if surrounded by
  /// whitespace or string boundaries.
  BoolColumn get requiresSpaces =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// True for tokens shipped with the app, so a "reset to defaults" is
  /// possible without discarding the user's own additions.
  BoolColumn get isBuiltIn => boolean().withDefault(const Constant(false))();
}

/// A remembered resolution for a raw credit string.
///
/// The app learns: once the user confirms that `"Name1 x Name2"` means two
/// specific artists, that decision is stored here and applied directly the
/// next time the same string appears, without re-guessing.
@TableIndex(name: 'idx_split_rules_key', columns: {#rawCreditKey})
class CreditSplitRules extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The credit string as it appears in files.
  TextColumn get rawCredit => text()();

  /// Normalised [rawCredit]. The lookup key.
  TextColumn get rawCreditKey => text().unique()();

  /// JSON array of `{"artistId": n, "role": "...", "creditedAs": "..."}`,
  /// in credit order.
  TextColumn get resolution => text()();

  /// True when a human confirmed it. Confirmed rules are applied silently;
  /// unconfirmed ones are suggestions.
  BoolColumn get isUserConfirmed =>
      boolean().withDefault(const Constant(false))();

  IntColumn get appliedCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
}

/// A credit the splitter was not confident enough to apply on its own.
///
/// Rather than guess wrong and quietly corrupt the library, ambiguous credits
/// land here for review. The track still plays; it is only its credits that
/// wait.
@TableIndex(name: 'idx_pending_credits_track', columns: {#trackId})
class PendingCredits extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();

  TextColumn get rawCredit => text()();

  /// JSON array of candidate interpretations, best first, each with a
  /// confidence and the artists it would create or link.
  TextColumn get suggestions => text()();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
}
