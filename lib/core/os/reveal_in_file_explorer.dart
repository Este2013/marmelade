import 'dart:io';

import '../logging/app_log.dart';

/// How long a path can be before Explorer's own `/select,` handling gives up
/// and falls back to a default folder instead of the one asked for.
///
/// Windows' classic `MAX_PATH` is 260; the real ceiling for `/select,`
/// specifically was found empirically against this app's own library paths
/// (a 260-character path reliably failed; a 188-character one reliably
/// worked), not from documentation, so a margin is kept below it.
const _selectPathLimit = 240;

/// Reveals [filePath] in Windows Explorer, highlighting it when the path is
/// short enough for Explorer to manage that; otherwise opens its containing
/// folder instead of failing outright.
///
/// Two separate bugs were reproduced directly against this app's own music
/// paths (nested `[Collection] Artist\Album (long soundtrack title)\...`
/// folders routinely have both problems) before writing this, and both look
/// identical from the outside: Explorer opens, but lands on the user's
/// Documents folder instead of the file's.
///
/// The first is quoting. `explorer.exe /select,"C:\path with spaces\x.mp3"`
/// -- quote starting right after the comma -- is the form Explorer actually
/// understands. Handing `/select,"..."` to `Process.start` as one argument
/// does not produce that: `Process.start` quotes an *entire* argument that
/// contains spaces, so the comma ends up *inside* the quotes along with
/// everything else, and Explorer's own parser cannot make sense of that.
/// Routing the already-correctly-quoted command through PowerShell's
/// `Start-Process -ArgumentList` is what gets the quote in the right place;
/// verified against this exact failure by dumping the raw argv a spawned
/// process actually received.
///
/// The second is Explorer's own length limit on `/select,`, independent of
/// quoting -- confirmed by testing the identical, correctly-quoted command
/// with paths of different lengths. Past [_selectPathLimit], `/select,` is
/// skipped entirely and the parent folder is opened plainly instead, which
/// does not share the limit.
Future<void> revealInFileExplorer(String filePath) async {
  final normalized = filePath.replaceAll('/', r'\');

  if (normalized.length > _selectPathLimit) {
    final lastSeparator = normalized.lastIndexOf(r'\');
    final folder =
        lastSeparator == -1 ? normalized : normalized.substring(0, lastSeparator);
    AppLog.instance.debug(
      'path too long for Explorer\'s /select, opening the folder instead',
      tag: 'library',
      fields: {'length': normalized.length, 'folder': folder},
    );
    await Process.start('explorer.exe', [folder]);
    return;
  }

  final escaped = normalized.replaceAll("'", "''");
  await Process.start(
    'powershell.exe',
    [
      '-NoProfile',
      '-WindowStyle', 'Hidden',
      '-Command',
      "Start-Process explorer.exe -ArgumentList '/select,\"$escaped\"'",
    ],
  );
}
