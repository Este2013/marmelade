import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/edit_repository.dart';
import '../../data/repositories/tag_repository.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import 'edit_widgets.dart';
import 'editor_save_state.dart';
import 'tag_section.dart';
import 'picture_section.dart';

/// Everything about one album that a person can change.
class AlbumEditorView extends ConsumerWidget {
  const AlbumEditorView({
    super.key,
    required this.albumId,
    required this.onBack,
    required this.saveState,
  });

  final int albumId;
  final VoidCallback onBack;

  /// Bridges the form's dirty/saving state to [AlbumEditorChrome], which is
  /// built outside this widget's own subtree -- see `AppShell._editAlbum`.
  final EditorSaveState saveState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(albumEditProvider(albumId));

    return album.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load that album',
        message: '$error',
      ),
      data: (edit) => edit == null
          ? EmptyState(
              icon: Icons.album_outlined,
              title: 'That album is gone',
              message: 'It may have been removed by a rescan.',
              action:
                  FilledButton(onPressed: onBack, child: const Text('Back')),
            )
          : _Editor(
              key: ValueKey(edit.id),
              edit: edit,
              onBack: onBack,
              saveState: saveState,
            ),
    );
  }
}

/// An album editor's identity (cover, title, track count) and Save button,
/// merged into the window's title bar. See [AppShell].
///
/// A [ConsumerWidget] rather than taking the album's title as a parameter,
/// matching [AlbumDetailChrome]: the chrome is built before the page's own
/// data has necessarily loaded, so it watches [albumEditProvider] itself.
/// [saveState] is what actually drives the Save button, since "is the form
/// dirty" lives in the editor's own widget state, not in a provider.
class AlbumEditorChrome extends ConsumerWidget {
  const AlbumEditorChrome({
    super.key,
    required this.albumId,
    required this.onBack,
    required this.saveState,
  });

  final int albumId;
  final VoidCallback onBack;
  final EditorSaveState saveState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edit = ref.watch(albumEditProvider(albumId)).value;
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: saveState,
      builder: (context, _) => Row(
        children: [
          IconButton(
            tooltip: 'Back',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          const SizedBox(width: 8),
          if (edit == null)
            const Spacer()
          else ...[
            Artwork(
              storedPath: edit.imagePath,
              size: 36,
              borderRadius: 6,
              fallbackSeed: edit.title,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    edit.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  Text(
                    '${pluralize(edit.trackCount, 'track')}'
                    '${edit.isVerified ? ' · reviewed' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: saveState.saving || !saveState.dirty
                ? null
                : saveState.onSave,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({
    super.key,
    required this.edit,
    required this.onBack,
    required this.saveState,
  });

  final AlbumEdit edit;
  final VoidCallback onBack;
  final EditorSaveState saveState;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final TextEditingController _title;
  late final TextEditingController _sortTitle;
  late final TextEditingController _year;

  late int? _albumArtistId;
  late String? _albumArtistName;
  late bool _variousArtists;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final edit = widget.edit;
    _title = TextEditingController(text: edit.title);
    _sortTitle = TextEditingController(text: edit.sortTitle ?? '');
    _year = TextEditingController(text: edit.releaseYear?.toString() ?? '');
    _albumArtistId = edit.albumArtistId;
    _albumArtistName = edit.albumArtistName;
    _variousArtists = edit.isVariousArtists;
    for (final controller in [_title, _sortTitle, _year]) {
      controller.addListener(_onFieldChanged);
    }
  }

  /// Rebuilds as the fields are typed in.
  ///
  /// A TextEditingController changing does not rebuild the widget that owns it,
  /// so without this the Save button never notices the form is dirty and stays
  /// disabled however much is typed.
  void _onFieldChanged() => setState(() {});


  @override
  void dispose() {
    _title.dispose();
    _sortTitle.dispose();
    _year.dispose();
    super.dispose();
  }

  bool get _dirty {
    final edit = widget.edit;
    return _title.text.trim() != edit.title ||
        _sortTitle.text.trim() != (edit.sortTitle ?? '') ||
        _year.text.trim() != (edit.releaseYear?.toString() ?? '') ||
        _albumArtistId != edit.albumArtistId ||
        _variousArtists != edit.isVariousArtists;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(editRepositoryProvider).saveAlbum(
            widget.edit.id,
            title: _title.text,
            sortTitle: _sortTitle.text,
            releaseYear: int.tryParse(_year.text.trim()),
            albumArtistId: _albumArtistId,
            clearAlbumArtist: _albumArtistId == null,
            isVariousArtists: _variousArtists,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final edit = widget.edit;
    final theme = Theme.of(context);

    // After every build, not during it: notifying the chrome's Save button
    // mid-build risks tripping Flutter's "setState during build" guard, and
    // a one-frame-later sync is not something anyone typing can notice.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.saveState.update(
        dirty: _dirty,
        saving: _saving,
        onSave: _saving || !_dirty ? null : _save,
      );
    });

    return Column(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
                children: [
                  EditSection(
                    title: 'Release',
                    subtitle: 'Changing the title also changes what file '
                        'metadata is matched against, so a rescan keeps '
                        'finding this album.',
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        EditField(
                          controller: _title,
                          label: 'Title',
                          width: 360,
                        ),
                        EditField(
                          controller: _sortTitle,
                          label: 'Sort title',
                          hint: 'Wall, The',
                          width: 240,
                        ),
                        EditField(
                          controller: _year,
                          label: 'Year',
                          width: 120,
                          keyboardType: TextInputType.number,
                        ),
                      ],
                    ),
                  ),
                  PictureSection(
                    imagePath: edit.imagePath,
                    fallbackSeed: edit.title,
                    subtitle: 'The sleeve. Every track on the release falls '
                        'back to it when it has no picture of its own.',
                    onPick: (file) => ref
                        .read(editRepositoryProvider)
                        .setAlbumPicture(edit.id, file),
                    onClear: () => ref
                        .read(editRepositoryProvider)
                        .clearAlbumPicture(edit.id),
                  ),
                  AliasSection(
                    title: 'Other titles',
                    subtitle: 'Alternative titles that should find this '
                        'release. A native script title, a romanisation, or '
                        'just what the files happen to say.',
                    aliases: edit.aliases,
                    emptyMessage: 'No other titles yet.',
                    addLabel: 'Add a title',
                    enabled: !_saving,
                    onAdd: (alias, kind) => ref
                        .read(editRepositoryProvider)
                        .addAlbumAlias(edit.id, alias, kind: kind),
                    onRemove: (id) =>
                        ref.read(editRepositoryProvider).removeAlbumAlias(id),
                  ),
                  TagSection(target: TagTarget.album, id: edit.id),
                  EditSection(
                    title: 'Album artist',
                    subtitle: 'Who the release as a whole is by. Individual '
                        'tracks keep their own credits.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _variousArtists
                                  ? Text(
                                      'Various artists',
                                      style: theme.textTheme.bodyLarge,
                                    )
                                  : Text(
                                      _albumArtistName ?? 'Not set',
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                        color: _albumArtistName == null
                                            ? theme
                                                .colorScheme.onSurfaceVariant
                                            : null,
                                      ),
                                    ),
                            ),
                            if (!_variousArtists) ...[
                              if (_albumArtistId != null)
                                IconButton(
                                  tooltip: 'Clear',
                                  onPressed: _saving
                                      ? null
                                      : () => setState(() {
                                            _albumArtistId = null;
                                            _albumArtistName = null;
                                          }),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: _saving ? null : _pickAlbumArtist,
                                icon: const Icon(Icons.person_search, size: 18),
                                label: const Text('Choose'),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _variousArtists,
                          onChanged: (value) =>
                              setState(() => _variousArtists = value),
                          title: const Text('Various artists'),
                          subtitle: const Text(
                            'A compilation, where no single artist owns the '
                            'release.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickAlbumArtist() async {
    final picked = await pickArtist(
      context,
      ref,
      title: 'Album artist for ${widget.edit.title}',
    );
    if (picked == null) return;
    setState(() {
      _albumArtistId = picked.id;
      _albumArtistName = picked.name;
    });
  }
}
