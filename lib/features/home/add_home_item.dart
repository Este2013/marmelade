import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart' show SearchEntity;
import '../../data/db/enums.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../playlists/smart_query_field.dart';

/// What the dialog decided to add.
typedef NewHomeItem = ({HomeItemKind kind, int? refId, String? label, String? query});

/// Asks what to put on the home page.
///
/// One dialog for all six kinds rather than six entry points, because the
/// question somebody actually has is "I want this thing here", and which of
/// the six it happens to be is an answer, not a prior decision. The kind
/// chooser is right at the top and the rest of the dialog follows it.
///
/// Returns null when dismissed.
Future<NewHomeItem?> addHomeItem(BuildContext context, WidgetRef ref, {required String title}) {
  return showDialog<NewHomeItem>(
    context: context,
    builder: (context) => _AddHomeItemDialog(title: title, ref: ref),
  );
}

class _AddHomeItemDialog extends StatefulWidget {
  const _AddHomeItemDialog({required this.title, required this.ref});

  final String title;
  final WidgetRef ref;

  @override
  State<_AddHomeItemDialog> createState() => _AddHomeItemDialogState();
}

class _AddHomeItemDialogState extends State<_AddHomeItemDialog> {
  final _search = TextEditingController();
  final _name = TextEditingController();
  final _query = TextEditingController();

  var _kind = HomeItemKind.album;
  var _searching = false;

  List<AlbumCard> _albums = const [];
  List<ArtistCard> _artists = const [];
  List<PlaylistCard> _playlists = const [];
  List<TrackRow> _tracks = const [];

  @override
  void dispose() {
    _search.dispose();
    _name.dispose();
    _query.dispose();
    super.dispose();
  }

  /// True for the kinds that are chosen by finding something in the library.
  bool get _picksFromLibrary => _kind != HomeItemKind.collection && _kind != HomeItemKind.query;

  Future<void> _run(String text) async {
    if (!_picksFromLibrary) return;
    setState(() => _searching = true);
    final results = await widget.ref.read(searchRepositoryProvider).search(text, perKind: 24, kinds: {_entityFor(_kind)});
    if (!mounted) return;
    setState(() {
      _albums = results.albums;
      _artists = results.artists;
      _playlists = results.playlists;
      _tracks = results.tracks;
      _searching = false;
    });
  }

  static SearchEntity _entityFor(HomeItemKind kind) => switch (kind) {
    HomeItemKind.album => SearchEntity.album,
    HomeItemKind.artist => SearchEntity.artist,
    HomeItemKind.playlist => SearchEntity.playlist,
    _ => SearchEntity.track,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 528,
        height: 480,
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kind in HomeItemKind.values)
                  ChoiceChip(
                    label: Text(kind.label),
                    selected: _kind == kind,
                    onSelected: (_) {
                      setState(() {
                        _kind = kind;
                        _albums = const [];
                        _artists = const [];
                        _playlists = const [];
                        _tracks = const [];
                      });
                      if (_search.text.isNotEmpty) _run(_search.text);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(child: _body(theme)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (!_picksFromLibrary) FilledButton(onPressed: _commit, child: const Text('Add')),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    switch (_kind) {
      case HomeItemKind.collection:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'Late night, Soundtracks, Stuff I keep forgetting', border: OutlineInputBorder()),
              onSubmitted: (_) => _commit(),
            ),
            const SizedBox(height: 12),
            Text(
              'A collection is an empty tile you drop other things into. Open '
              'it after adding it and use "Add items" inside -- a search '
              'can go in there too, alongside hand-picked things.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        );

      case HomeItemKind.query:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'What to call it on the home page', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            SmartQueryField(controller: _query, onSubmitted: (_) => _commit()),
          ],
        );

      default:
        return Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: _run,
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Find a ${_kind.label.toLowerCase()}', border: const OutlineInputBorder(), isDense: true),
            ),
            const SizedBox(height: 12),
            Expanded(child: _results(theme)),
          ],
        );
    }
  }

  Widget _results(ThemeData theme) {
    final rows = switch (_kind) {
      HomeItemKind.album => [for (final a in _albums) (id: a.id, title: a.title, subtitle: a.artistName, image: a.imagePath)],
      HomeItemKind.artist => [for (final a in _artists) (id: a.id, title: a.name, subtitle: pluralizeTracks(a.trackCount), image: a.imagePath)],
      HomeItemKind.playlist => [for (final p in _playlists) (id: p.id, title: p.name, subtitle: pluralizeTracks(p.trackCount), image: p.imagePath)],
      _ => [for (final t in _tracks) (id: t.id, title: t.title, subtitle: t.credits.isEmpty ? null : t.credits.first.name, image: t.imagePath)],
    };

    if (rows.isEmpty) {
      return Center(
        child: Text(
          _search.text.trim().isEmpty
              ? 'Start typing to find one.'
              : _searching
              ? 'Searching...'
              : 'Nothing matches that.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return ListTile(
          dense: true,
          leading: Artwork(storedPath: row.image, size: 36, borderRadius: _kind.isRound ? 999 : 6, fallbackSeed: row.title),
          title: Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: row.subtitle == null ? null : Text(row.subtitle!),
          onTap: () => Navigator.of(context).pop((kind: _kind, refId: row.id, label: null, query: null)),
        );
      },
    );
  }

  void _commit() {
    final name = _name.text.trim();
    switch (_kind) {
      case HomeItemKind.collection:
        if (name.isEmpty) return;
        Navigator.of(context).pop((kind: _kind, refId: null, label: name, query: null));
      case HomeItemKind.query:
        final query = _query.text.trim();
        if (query.isEmpty) return;
        Navigator.of(context).pop((kind: _kind, refId: null, label: name.isEmpty ? query : name, query: query));
      default:
        return;
    }
  }
}

/// "12 tracks", for the picker's second line.
String pluralizeTracks(int count) => '$count ${count == 1 ? 'track' : 'tracks'}';
