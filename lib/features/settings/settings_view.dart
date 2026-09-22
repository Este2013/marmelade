import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/logging/app_log.dart';
import '../../data/db/database.dart';
import '../../data/db/sqlite_diagnostics.dart';
import '../../data/indexer/library_indexer.dart';
import '../library/add_music_folder.dart';
import '../../widgets/time_text.dart';
import 'appearance_section.dart';
import 'missing_files_section.dart';
import 'transfer_section.dart';
import 'updates_tile.dart';

/// Where the project lives, shown in settings and used by the updater.
const repositoryUrl = 'https://github.com/Este2013/marmelade';

/// One of settings' tabs, stable enough for another page to ask for by name
/// -- the "add a folder" empty state wants Library specifically, not
/// whichever tab settings happened to open on last.
enum SettingsTab { appearance, library, transfer, diagnostics, about }

/// One tab of the settings page.
typedef _SettingsTabInfo = ({
  SettingsTab id,
  IconData icon,
  String label,
  List<Widget> sections,
});

/// Grouped so each tab answers one question -- how does it look, what is in
/// my library, how do I move it, is anything wrong, what version is this --
/// rather than being one long scroll nobody remembers the order of.
///
/// Appearance leads because it is what most people touch first and most
/// often; the order otherwise follows [SettingsTab]'s own.
final _tabs = <_SettingsTabInfo>[
  (
    id: SettingsTab.appearance,
    icon: Icons.palette_outlined,
    label: 'Appearance',
    sections: const [AppearanceSection()],
  ),
  (
    id: SettingsTab.library,
    icon: Icons.library_music_outlined,
    label: 'Library',
    sections: const [_LibrarySection(), _StatisticsSection()],
  ),
  (
    id: SettingsTab.transfer,
    icon: Icons.sync_outlined,
    label: 'Transfer',
    sections: const [TransferSection()],
  ),
  (
    id: SettingsTab.diagnostics,
    icon: Icons.bug_report_outlined,
    label: 'Diagnostics',
    sections: const [_DiagnosticsSection()],
  ),
  (
    id: SettingsTab.about,
    icon: Icons.info_outline,
    label: 'About',
    sections: const [_AboutSection()],
  ),
];

/// A one-shot request to open settings on a particular tab, next time it is
/// looked at.
///
/// Settings' root page is built once and then kept alive behind the shell's
/// `IndexedStack` -- switching sections only changes which one is visible --
/// so a constructor argument handed in when navigating there would only ever
/// take effect the very first time settings was opened this session. A
/// provider [SettingsView] itself watches works regardless of whether it is
/// already mounted: something that wants a specific tab (the "add a folder"
/// empty state, wanting Library) sets this immediately before selecting the
/// settings section, and the page consumes it and puts itself back to null.
final settingsTabRequestProvider =
    NotifierProvider<ViewSetting<SettingsTab?>, SettingsTab?>(
  () => ViewSetting(null),
);

int _indexOf(SettingsTab? tab) =>
    tab == null ? 0 : _tabs.indexWhere((t) => t.id == tab).clamp(0, _tabs.length - 1);

/// Settings, organised into tabs so a section is a click away rather than a
/// scroll -- the alternative this replaced was one column holding folders,
/// appearance, transfer, library stats, diagnostics and the changelog end to
/// end, which made "where was that setting" its own small chore.
class SettingsView extends ConsumerStatefulWidget {
  const SettingsView({super.key});

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;

  @override
  void initState() {
    super.initState();
    // Covers the very first time this page is built; ref.listen in build
    // covers every time after, while it is already mounted and merely being
    // shown again. Consumed either way, so a later plain visit does not
    // keep jumping back to a tab that was only ever asked for once.
    final requested = ref.read(settingsTabRequestProvider);
    _controller = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: _indexOf(requested),
    );
    if (requested != null) {
      Future.microtask(
        () => ref.read(settingsTabRequestProvider.notifier).set(null),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsTabRequestProvider, (_, requested) {
      if (requested == null) return;
      _controller.animateTo(_indexOf(requested));
      ref.read(settingsTabRequestProvider.notifier).set(null);
    });

    return Column(
      children: [
        // Above the tabs and not inside any of them: a library that has
        // lost files is the one thing here a person needs to act on rather
        // than merely configure, and it should not depend on which tab
        // happens to be open when that happens.
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: MissingFilesSection(),
        ),
        TabBar(
          controller: _controller,
          // Filling the width rather than shrinking to each label -- five
          // tabs sized to their own text left a lot of the bar looking like
          // dead space, and one whose target is however wide its own name
          // happens to be is a smaller, less consistent target than its
          // neighbours.
          tabs: [
            for (final tab in _tabs) Tab(icon: Icon(tab.icon), text: tab.label),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _controller,
            children: [for (final tab in _tabs) _TabBody(tab.sections)],
          ),
        ),
      ],
    );
  }
}

/// One tab's sections, laid out the same way the single scroll used to.
class _TabBody extends StatelessWidget {
  const _TabBody(this.sections);

  final List<Widget> sections;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        children: [
          for (final (index, section) in sections.indexed) ...[
            if (index > 0) const SizedBox(height: 28),
            section,
          ],
        ],
      );
}

/// Matches one of [AppLog]'s own lines: `HH:MM:SS.mmm  LEVEL  [tag] message`.
/// Whitespace is matched loosely rather than assuming the exact column
/// widths the writer pads to, so this survives a formatting tweak there.
final _logLinePattern =
    RegExp(r'^(\d{2}:\d{2}:\d{2}\.\d{3})\s+(\S+)\s+(?:\[(\w+)\]\s+)?(.*)$');

/// Colours one already-formatted log line for display: the timestamp in
/// green, the level in a colour keyed to its severity, a `[tag]` in grey,
/// and the message itself left as the theme's own text colour.
///
/// A line this cannot parse -- a wrapped stack frame, an error's own indented
/// detail line -- is not a bug to fail loudly over: it prints uncoloured
/// rather than disappearing.
///
/// Every colour is picked separately for light and dark, rather than derived
/// from one value: green legible on a near-black background reads as barely
/// there on a near-white one, and the reverse for a colour picked the other
/// way -- there is no single shade that works against both, only two that
/// agree on what they mean.
TextSpan _colourLogLine(String line, ColorScheme scheme) {
  final match = _logLinePattern.firstMatch(line);
  if (match == null) {
    return TextSpan(text: line, style: TextStyle(color: scheme.onSurfaceVariant));
  }

  final dark = scheme.brightness == Brightness.dark;
  final timestamp = match.group(1)!;
  final levelTag = match.group(2)!;
  final tag = match.group(3);
  final rest = match.group(4) ?? '';
  final level =
      LogLevel.values.where((l) => l.tag.trim() == levelTag.trim()).firstOrNull;

  final timestampColor =
      dark ? const Color(0xFF7EE2A0) : const Color(0xFF1B7A38);
  final levelColor = switch (level) {
    LogLevel.trace => dark ? const Color(0xFF98A5B3) : const Color(0xFF5B6472),
    LogLevel.debug => dark ? const Color(0xFFBFC8D2) : const Color(0xFF3F4750),
    LogLevel.info => dark ? const Color(0xFF8AC1FF) : const Color(0xFF11579E),
    LogLevel.warn => dark ? const Color(0xFFFFC24D) : const Color(0xFF8A5A00),
    LogLevel.error => dark ? const Color(0xFFFF8A8A) : const Color(0xFFB3261E),
    null => scheme.onSurface,
  };
  final tagColor = dark ? const Color(0xFFA6ADB4) : const Color(0xFF6B7280);

  return TextSpan(
    style: TextStyle(color: scheme.onSurface),
    children: [
      TextSpan(
        text: timestamp,
        style: TextStyle(color: timestampColor, fontWeight: FontWeight.w600),
      ),
      const TextSpan(text: '  '),
      TextSpan(
        text: levelTag,
        style: TextStyle(color: levelColor, fontWeight: FontWeight.w600),
      ),
      const TextSpan(text: '  '),
      if (tag != null) TextSpan(text: '[$tag] ', style: TextStyle(color: tagColor)),
      TextSpan(text: rest),
    ],
  );
}

/// The log, and a way to get at it.
///
/// Worth a place in the UI rather than only on disk: when the app misbehaves,
/// "no errors in the terminal" is not the same as "nothing went wrong", and the
/// log is the only thing that survives a hard exit.
class _DiagnosticsSection extends ConsumerStatefulWidget {
  const _DiagnosticsSection();

  @override
  ConsumerState<_DiagnosticsSection> createState() =>
      _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends ConsumerState<_DiagnosticsSection> {
  var _expanded = false;

  /// Read from disk on demand rather than on every build: a full session log
  /// can be thousands of lines, and nothing here needs to notice a new line
  /// arriving before the next time this is asked to reload.
  List<String>? _lines;

  void _reload() => setState(() => _lines = AppLog.instance.readAllLines());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final log = AppLog.instance;
    final file = log.file;
    final lines = _expanded ? (_lines ??= log.readAllLines()) : const <String>[];
    final level = LogLevel.of(ref.watch(logLevelProvider));

    return _Section(
      title: 'Diagnostics',
      subtitle: 'Every session writes a log, flushed line by line so it '
          'survives a crash.',
      children: [
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(file == null ? 'Logging to nowhere' : 'Session log'),
          subtitle: Text(
            file?.path ?? 'A log file could not be opened.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Copy path',
                onPressed: file == null
                    ? null
                    : () async {
                        await Clipboard.setData(
                            ClipboardData(text: file.path));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Log path copied')),
                        );
                      },
                icon: const Icon(Icons.copy_all_outlined),
              ),
              IconButton(
                tooltip: 'Show in folder',
                onPressed: file == null
                    ? null
                    : () => launchUrl(Uri.file(file.parent.path)),
                icon: const Icon(Icons.folder_open_outlined),
              ),
            ],
          ),
        ),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('Log level'),
          subtitle: Text(
            'What gets written from now on. Lower levels write more, and '
            'grow the file faster.',
          ),
          trailing: DropdownButton<LogLevel>(
            value: level,
            items: [
              for (final option in LogLevel.values)
                DropdownMenuItem(value: option, child: Text(option.label)),
            ],
            onChanged: (value) {
              if (value == null) return;
              // Applied immediately, not only on the next launch: someone
              // turning this up is usually about to reproduce something right
              // now, not next time they open the app.
              log.minLevel = value;
              ref.read(logLevelProvider.notifier).set(value.name);
            },
          ),
        ),
        ListTile(
          leading: const Icon(Icons.terminal),
          title: const Text('This session\'s log'),
          subtitle: Text(
            _expanded
                ? '${pluralize(lines.length, 'line')} · newest last'
                : 'Read straight from the file -- not just what fits in '
                    'memory',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_expanded)
                IconButton(
                  tooltip: 'Reload from disk',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            ],
          ),
          onTap: () => setState(() {
            _expanded = !_expanded;
            if (_expanded) _lines = log.readAllLines();
          }),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            height: 400,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: lines.isEmpty
                ? Center(
                    child: Text(
                      'Nothing logged yet.',
                      style: theme.textTheme.bodySmall,
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      reverse: true,
                      itemCount: lines.length,
                      itemBuilder: (context, index) => Text.rich(
                        _colourLogLine(
                          lines[lines.length - 1 - index],
                          theme.colorScheme,
                        ),
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
          ),
      ],
    );
  }
}

/// A titled group of settings.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.subtitle});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        Card(
          color: theme.colorScheme.surfaceContainer,
          child: Column(children: children),
        ),
      ],
    );
  }
}

/// Watched folders, and the scan controls.
class _LibrarySection extends ConsumerWidget {
  const _LibrarySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(libraryFoldersProvider);
    final progress = ref.watch(indexProgressProvider);
    final jobs = ref.read(indexProgressProvider.notifier);

    return _Section(
      title: 'Music folders',
      subtitle: 'marmelade indexes these folders and watches them for changes.',
      children: [
        ...?folders.value?.map(
          (folder) => _FolderTile(folder: folder),
        ),
        if (folders.value?.isEmpty ?? true)
          const ListTile(
            leading: Icon(Icons.folder_off_outlined),
            title: Text('No folders yet'),
            subtitle: Text('Add one to start building your library.'),
          ),
        if (progress != null) _ScanProgressTile(progress: progress),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: progress != null
                    ? null
                    : () => pickAndAddMusicFolder(context, ref),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add folder'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: progress != null || (folders.value?.isEmpty ?? true)
                    ? null
                    : () => _refresh(context, jobs),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh library'),
              ),
            ],
          ),
        ),
      ],
    );
  }


  Future<void> _refresh(
    BuildContext context,
    IndexJobController jobs,
  ) async {
    final outcomes = await jobs.refreshAll();
    if (!context.mounted) return;
    showScanOutcome(context, outcomes);
  }

}

class _FolderTile extends ConsumerWidget {
  const _FolderTile({required this.folder});

  final LibraryFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final db = ref.watch(databaseProvider);

    return ListTile(
      leading: Icon(
        folder.enabled ? Icons.folder_outlined : Icons.folder_off_outlined,
        color: folder.enabled ? null : theme.disabledColor,
      ),
      title: Text(
        folder.displayName ?? folder.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          pluralize(folder.trackedFileCount, 'file'),
          if (folder.lastScanDurationMs != null)
            'scanned in ${folder.lastScanDurationMs} ms',
          if (!folder.enabled) 'disabled',
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: folder.enabled,
            onChanged: (value) => (db.update(db.libraryFolders)
                  ..where((t) => t.id.equals(folder.id)))
                .write(LibraryFoldersCompanion(enabled: Value(value))),
          ),
          IconButton(
            tooltip: 'Remove from library',
            onPressed: () => _confirmRemove(context, ref, db),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  /// Removing a folder discards its tracks, so it asks first.
  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    MarmeladeDatabase db,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this folder?'),
        content: Text(
          'The files on disk are left alone, but marmelade will forget the '
          '${pluralize(folder.trackedFileCount, 'track')} it indexed from '
          '${folder.path}, along with their play counts and ratings.\n\n'
          'Disabling the folder instead keeps all of that.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await (db.delete(db.libraryFolders)..where((t) => t.id.equals(folder.id)))
        .go();
  }
}

/// A progress row shown while a scan runs.
class _ScanProgressTile extends StatelessWidget {
  const _ScanProgressTile({required this.progress});

  final IndexProgress progress;

  @override
  Widget build(BuildContext context) {
    final label = switch (progress.phase) {
      IndexPhase.scanning => 'Looking for files',
      IndexPhase.reconciling => 'Working out what changed',
      IndexPhase.readingTags => 'Reading tags',
      IndexPhase.resolvingCredits => 'Matching artists',
      IndexPhase.writing => 'Saving',
      IndexPhase.artwork => 'Importing artwork',
      IndexPhase.indexingSearch => 'Building the search index',
      IndexPhase.done => 'Finishing up',
    };

    return ListTile(
      leading: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
      title: Text(label),
      subtitle: progress.total == 0
          ? (progress.detail == null ? null : Text(progress.detail!))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress.fraction),
                const SizedBox(height: 4),
                Text('${progress.completed} of ${progress.total}'),
              ],
            ),
    );
  }
}

/// Library counts, and anything waiting for the user's attention.
class _StatisticsSection extends ConsumerWidget {
  const _StatisticsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(libraryCountsProvider);
    final data = counts.value;

    return _Section(
      title: 'Library',
      children: [
        if (data == null)
          const ListTile(title: Text('Counting...'))
        else ...[
          ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: Text(
              '${pluralize(data.tracks, 'track')} · '
              '${pluralize(data.albums, 'album')} · '
              '${pluralize(data.artists, 'artist')}',
            ),
            subtitle: Text(
              '${pluralize(data.files, 'file')} · '
              '${formatDurationLong(data.totalDuration)} of music',
            ),
          ),
          if (data.missingFiles > 0)
            ListTile(
              leading: Icon(
                Icons.link_off,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(pluralize(data.missingFiles, 'missing file')),
              subtitle: const Text(
                'Kept, along with their ratings and play counts, in case the '
                'drive comes back.',
              ),
            ),
          if (data.pendingCredits > 0)
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: Text(
                '${pluralize(data.pendingCredits, 'credit')} to review',
              ),
              subtitle: const Text(
                'Artist names marmelade would rather ask about than guess at.',
              ),
            ),
        ],
        const _SearchIndexTile(),
        const _ImageCacheTile(),
      ],
    );
  }
}

/// What search knows about, and a way to make it agree with the library again.
///
/// The index is kept up to date as things change, which means a bug in that
/// bookkeeping leaves search quietly wrong -- finding a name nobody has used
/// for months, or missing one that is right there. Rebuilding is a handful of
/// bulk statements, so the repair is cheap; not having one at all is what makes
/// a stale index permanent.
class _SearchIndexTile extends ConsumerStatefulWidget {
  const _SearchIndexTile();

  @override
  ConsumerState<_SearchIndexTile> createState() => _SearchIndexTileState();
}

class _SearchIndexTileState extends ConsumerState<_SearchIndexTile> {
  var _rebuilding = false;

  Future<void> _rebuild() async {
    setState(() => _rebuilding = true);
    try {
      // SearchIndexer.rebuildAll already recovers on its own from a
      // corrupted index -- recreating the tables and rebuilding again --
      // so reaching this catch means that retry also failed.
      await ref.read(searchIndexerProvider).rebuildAll();
      ref.invalidate(searchIndexCountsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Search index rebuilt')),
      );
    } catch (error, stack) {
      AppLog.instance.error(
        'search index rebuild failed',
        tag: 'search',
        error: error,
        stack: stack,
        fields: describeDatabaseError(error),
      );
      if (!mounted) return;
      final corrupt = isDatabaseCorruption(error);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            corrupt
                ? 'The search index could not be repaired'
                : 'Rebuild failed',
          ),
          content: Text(
            corrupt
                ? 'The search index is corrupted on disk, and recreating it '
                    'from scratch just now did not fix it. Your library '
                    'itself is untouched -- this is only the search index. '
                    'Closing and reopening marmelade may help; check the '
                    'log if it keeps happening.'
                : '$error',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _rebuilding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = ref.watch(searchIndexCountsProvider).value;

    return ListTile(
      leading: const Icon(Icons.manage_search),
      title: const Text('Search index'),
      subtitle: Text(
        switch (counts) {
          null => 'Counting...',
          final c when c.trigrams == 0 =>
            '${pluralize(c.tokens, 'entry', 'entries')} · no substring index, '
                'so mid-word and Japanese search are unavailable',
          final c => '${pluralize(c.tokens, 'entry', 'entries')} · '
              '${pluralize(c.trigrams, 'substring entry', 'substring entries')}',
        },
      ),
      trailing: _rebuilding
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: 'Rebuild from the library',
              onPressed: _rebuild,
              icon: const Icon(Icons.refresh),
            ),
    );
  }
}

/// Forces artwork to redecode from disk.
///
/// Artwork itself is never resized on disk -- [Artwork] decodes straight
/// from the original file at whatever width the widget needs -- so this
/// cannot fix a cover that is genuinely low-resolution in the library. What
/// it clears is Flutter's own decoded-bitmap cache, which is worth trying
/// first regardless: a page that only ever saw a cover small (a grid tile,
/// a search result) can be holding onto that small decode, and this is the
/// only way to make it let go without restarting the app.
class _ImageCacheTile extends StatefulWidget {
  const _ImageCacheTile();

  @override
  State<_ImageCacheTile> createState() => _ImageCacheTileState();
}

class _ImageCacheTileState extends State<_ImageCacheTile> {
  var _clearing = false;

  Future<void> _clear() async {
    setState(() => _clearing = true);
    final cache = PaintingBinding.instance.imageCache;
    final cleared = cache.currentSize;
    cache.clear();
    cache.clearLiveImages();
    if (!mounted) return;
    setState(() => _clearing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cleared == 0
              ? 'Nothing was cached'
              : 'Cleared ${pluralize(cleared, 'cached image')} -- reopen a '
                  'page to see it redecode',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.image_not_supported_outlined),
      title: const Text('Image cache'),
      subtitle: const Text(
        'Worth a try if a cover looks softer than it should. Will not help '
        'if the picture on disk is itself low-resolution.',
      ),
      trailing: _clearing
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : IconButton(
              tooltip: 'Clear',
              onPressed: _clear,
              icon: const Icon(Icons.delete_outline),
            ),
    );
  }
}

/// Version, repository link and the debug entry points.
class _AboutSection extends ConsumerWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Section(
      title: 'About',
      children: [
        const ListTile(
          leading: Icon(Icons.emoji_food_beverage_outlined),
          title: Text('marmelade'),
          subtitle: Text('we be jamming to the tunes'),
        ),
        const UpdatesTile(),
        ListTile(
          leading: const Icon(Icons.code),
          title: const Text('Source code'),
          subtitle: const Text(repositoryUrl),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => launchUrl(Uri.parse(repositoryUrl)),
        ),
      ],
    );
  }
}
