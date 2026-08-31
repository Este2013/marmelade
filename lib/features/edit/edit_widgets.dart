import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../widgets/time_text.dart';

/// A titled block on an editor page.
class EditSection extends StatelessWidget {
  const EditSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

/// A labelled text field sized for a form row.
class EditField extends StatelessWidget {
  const EditField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.width,
    this.maxLines = 1,
    this.keyboardType,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final double? width;
  final int maxLines;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
    return width == null ? field : SizedBox(width: width, child: field);
  }
}

/// The outcome of picking an artist.
typedef PickedArtist = ({int id, String name, ArtistKind kind, int trackCount});

/// Asks for an artist by name, searching names and aliases.
///
/// Returns null when dismissed. [exclude] keeps an artist from being offered
/// where it would make no sense -- a group as its own member, or an artist as
/// the thing it is being merged into.
Future<PickedArtist?> pickArtist(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  Set<int> exclude = const {},
}) {
  return showDialog<PickedArtist>(
    context: context,
    builder: (context) => _ArtistPickerDialog(
      title: title,
      exclude: exclude,
      ref: ref,
    ),
  );
}

class _ArtistPickerDialog extends StatefulWidget {
  const _ArtistPickerDialog({
    required this.title,
    required this.exclude,
    required this.ref,
  });

  final String title;
  final Set<int> exclude;
  final WidgetRef ref;

  @override
  State<_ArtistPickerDialog> createState() => _ArtistPickerDialogState();
}

class _ArtistPickerDialogState extends State<_ArtistPickerDialog> {
  final _controller = TextEditingController();
  List<PickedArtist> _results = const [];
  var _searching = false;
  var _creating = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    setState(() => _searching = true);
    final results = await widget.ref
        .read(editRepositoryProvider)
        .findArtists(query, exclude: widget.exclude);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by name or alias',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _controller.text.trim().isEmpty
                            ? 'Start typing to find an artist.'
                            : _searching
                                ? 'Searching...'
                                : 'Nothing matches that.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final artist = _results[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            artist.kind == ArtistKind.group ||
                                    artist.kind == ArtistKind.orchestra
                                ? Icons.groups_outlined
                                : Icons.person_outline,
                          ),
                          title: Text(artist.name),
                          subtitle:
                              Text(pluralize(artist.trackCount, 'track')),
                          onTap: () => Navigator.of(context).pop(artist),
                        );
                      },
                    ),
            ),
            // Offered whenever what is typed is not already an exact match.
            // Needing an artist who does not exist yet is the normal case when
            // correcting a credit, and leaving the editor to go and create one
            // first loses whatever else was being typed.
            if (_canCreate) ...[
              const Divider(height: 20),
              _CreateRow(
                name: _controller.text.trim(),
                busy: _creating,
                label: 'artist',
                onCreate: _create,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  /// Whether what is typed is worth offering to create.
  bool get _canCreate {
    final typed = _controller.text.trim();
    if (typed.isEmpty || _searching) return false;
    // An exact match exists, so a second artist with that name would be a
    // duplicate nobody could tell apart.
    return !_results.any(
      (artist) => artist.name.toLowerCase() == typed.toLowerCase(),
    );
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    setState(() => _creating = true);
    final id = await widget.ref.read(editRepositoryProvider).createArtist(name);
    if (!mounted) return;
    Navigator.of(context).pop((
      id: id,
      name: name,
      kind: ArtistKind.unknown,
      trackCount: 0,
    ));
  }
}

/// The outcome of picking an album.
typedef PickedAlbum = ({int id, String title, String? artistName});

/// Asks for an album by title, and offers to create one that does not exist.
Future<PickedAlbum?> pickAlbum(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  Set<int> exclude = const {},
}) {
  return showDialog<PickedAlbum>(
    context: context,
    builder: (context) => _AlbumPickerDialog(
      title: title,
      exclude: exclude,
      ref: ref,
    ),
  );
}

class _AlbumPickerDialog extends StatefulWidget {
  const _AlbumPickerDialog({
    required this.title,
    required this.exclude,
    required this.ref,
  });

  final String title;
  final Set<int> exclude;
  final WidgetRef ref;

  @override
  State<_AlbumPickerDialog> createState() => _AlbumPickerDialogState();
}

class _AlbumPickerDialogState extends State<_AlbumPickerDialog> {
  final _controller = TextEditingController();
  List<PickedAlbum> _results = const [];
  var _searching = false;
  var _creating = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    setState(() => _searching = true);
    final results = await widget.ref
        .read(editRepositoryProvider)
        .findAlbums(query, exclude: widget.exclude);
    if (!mounted) return;
    setState(() {
      _results = [
        for (final album in results)
          (id: album.id, title: album.title, artistName: album.artistName),
      ];
      _searching = false;
    });
  }

  bool get _canCreate {
    final typed = _controller.text.trim();
    if (typed.isEmpty || _searching) return false;
    return !_results.any(
      (album) => album.title.toLowerCase() == typed.toLowerCase(),
    );
  }

  Future<void> _create() async {
    final title = _controller.text.trim();
    if (title.isEmpty) return;
    setState(() => _creating = true);
    final id = await widget.ref.read(editRepositoryProvider).createAlbum(title);
    if (!mounted) return;
    Navigator.of(context).pop((id: id, title: title, artistName: null));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by title or alias',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _controller.text.trim().isEmpty
                            ? 'Start typing to find an album.'
                            : _searching
                                ? 'Searching...'
                                : 'Nothing matches that.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final album = _results[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.album_outlined),
                          title: Text(album.title),
                          subtitle: Text(album.artistName ?? 'Unknown artist'),
                          onTap: () => Navigator.of(context).pop(album),
                        );
                      },
                    ),
            ),
            if (_canCreate) ...[
              const Divider(height: 20),
              _CreateRow(
                name: _controller.text.trim(),
                busy: _creating,
                label: 'album',
                onCreate: _create,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The "create what I typed" row, shared by both pickers.
class _CreateRow extends StatelessWidget {
  const _CreateRow({
    required this.name,
    required this.busy,
    required this.label,
    required this.onCreate,
  });

  final String name;
  final bool busy;
  final String label;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Text(
            'No $label called "$name" yet.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.tonalIcon(
          onPressed: busy ? null : onCreate,
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add, size: 18),
          label: Text('Create $label'),
        ),
      ],
    );
  }
}

/// A friendlier name for an artist kind.
String artistKindLabel(ArtistKind kind) => switch (kind) {
      ArtistKind.person => 'Person',
      ArtistKind.group => 'Group',
      ArtistKind.orchestra => 'Orchestra',
      ArtistKind.character => 'Character',
      ArtistKind.unknown => 'Not set',
    };

/// A friendlier name for an alias kind.
String aliasKindLabel(AliasKind kind) => switch (kind) {
      AliasKind.alias => 'Alias',
      AliasKind.romanization => 'Romanisation',
      AliasKind.nativeScript => 'Native script',
      AliasKind.abbreviation => 'Abbreviation',
      AliasKind.misspelling => 'Misspelling',
      AliasKind.formerName => 'Former name',
      AliasKind.sortName => 'Sort name',
    };

/// A friendlier name for a credit role.
String creditRoleLabel(CreditRole role) => switch (role) {
      CreditRole.mainArtist => 'Main artist',
      CreditRole.featured => 'Featured',
      CreditRole.composer => 'Composer',
      CreditRole.lyricist => 'Lyricist',
      CreditRole.arranger => 'Arranger',
      CreditRole.producer => 'Producer',
      CreditRole.remixer => 'Remixer',
      CreditRole.vocalist => 'Vocalist',
      CreditRole.performer => 'Performer',
      CreditRole.conductor => 'Conductor',
      CreditRole.band => 'Band',
      CreditRole.originalArtist => 'Original artist',
      CreditRole.illustrator => 'Illustrator',
      CreditRole.mixEngineer => 'Mix engineer',
      CreditRole.masteringEngineer => 'Mastering engineer',
      CreditRole.other => 'Other',
    };
