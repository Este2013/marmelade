import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../data/repositories/edit_repository.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import 'edit_widgets.dart';

/// Everything about one track that a person can change, credits included.
class TrackEditorView extends ConsumerWidget {
  const TrackEditorView({
    super.key,
    required this.trackId,
    required this.onBack,
  });

  final int trackId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(trackEditProvider(trackId));

    return track.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load that track',
        message: '$error',
      ),
      data: (edit) => edit == null
          ? EmptyState(
              icon: Icons.music_off_outlined,
              title: 'That track is gone',
              message: 'It may have been removed by a rescan.',
              action:
                  FilledButton(onPressed: onBack, child: const Text('Back')),
            )
          : _Editor(key: ValueKey(edit.id), edit: edit, onBack: onBack),
    );
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({super.key, required this.edit, required this.onBack});

  final TrackEdit edit;
  final VoidCallback onBack;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final TextEditingController _title;
  late final TextEditingController _sortTitle;
  late final TextEditingController _trackNo;
  late final TextEditingController _discNo;
  late final TextEditingController _year;

  /// The credits as the editor has them, which may differ from what is stored
  /// until Save. Held as a list because the order is part of the meaning.
  late List<CreditEdit> _credits;

  var _saving = false;

  @override
  void initState() {
    super.initState();
    final edit = widget.edit;
    _title = TextEditingController(text: edit.title);
    _sortTitle = TextEditingController(text: edit.sortTitle ?? '');
    _trackNo = TextEditingController(text: edit.trackNo?.toString() ?? '');
    _discNo = TextEditingController(text: edit.discNo?.toString() ?? '');
    _year = TextEditingController(text: edit.releaseYear?.toString() ?? '');
    _credits = [...edit.credits];
    for (final controller in [
      _title,
      _sortTitle,
      _trackNo,
      _discNo,
      _year,
    ]) {
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
    _trackNo.dispose();
    _discNo.dispose();
    _year.dispose();
    super.dispose();
  }

  bool get _creditsChanged {
    final stored = widget.edit.credits;
    if (stored.length != _credits.length) return true;
    for (var i = 0; i < stored.length; i++) {
      if (stored[i].artistId != _credits[i].artistId ||
          stored[i].role != _credits[i].role) {
        return true;
      }
    }
    return false;
  }

  bool get _dirty {
    final edit = widget.edit;
    return _title.text.trim() != edit.title ||
        _sortTitle.text.trim() != (edit.sortTitle ?? '') ||
        _trackNo.text.trim() != (edit.trackNo?.toString() ?? '') ||
        _discNo.text.trim() != (edit.discNo?.toString() ?? '') ||
        _year.text.trim() != (edit.releaseYear?.toString() ?? '') ||
        _creditsChanged;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final repository = ref.read(editRepositoryProvider);
      await repository.saveTrack(
        widget.edit.id,
        title: _title.text,
        sortTitle: _sortTitle.text,
        trackNo: int.tryParse(_trackNo.text.trim()),
        discNo: int.tryParse(_discNo.text.trim()),
        releaseYear: int.tryParse(_year.text.trim()),
      );
      if (_creditsChanged) {
        await repository.setTrackCredits(widget.edit.id, [
          for (final credit in _credits)
            (
              artistId: credit.artistId,
              role: credit.role,
              creditedAs: credit.creditedAs,
            ),
        ]);
      }
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 24, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 8),
              Artwork(
                storedPath: edit.imagePath,
                size: 40,
                borderRadius: 6,
                fallbackSeed: edit.albumTitle ?? edit.title,
                fallbackIcon: Icons.music_note_outlined,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(edit.title, style: theme.textTheme.titleLarge),
                    Text(
                      [
                        if (edit.albumTitle != null) edit.albumTitle!,
                        if (edit.isVerified) 'reviewed',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _saving || !_dirty ? null : _save,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
                children: [
                  EditSection(
                    title: 'Track',
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
                          width: 240,
                        ),
                        EditField(
                          controller: _trackNo,
                          label: 'Track',
                          width: 100,
                          keyboardType: TextInputType.number,
                        ),
                        EditField(
                          controller: _discNo,
                          label: 'Disc',
                          width: 100,
                          keyboardType: TextInputType.number,
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
                  _creditsSection(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _creditsSection() {
    return EditSection(
      title: 'Credits',
      subtitle: 'Every artist on this track, and what they did. The order is '
          'the order they are shown in.',
      trailing: FilledButton.tonalIcon(
        onPressed: _saving ? null : _addCredit,
        icon: const Icon(Icons.person_add_outlined, size: 18),
        label: const Text('Add'),
      ),
      child: _credits.isEmpty
          ? Text(
              'No credits. A track with no artist is findable only by its '
              'title, which is rarely what you want.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            )
          : Column(
              children: [
                for (var i = 0; i < _credits.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _credits[i].creditedAs == null ||
                                    _credits[i].creditedAs == _credits[i].name
                                ? _credits[i].name
                                : '${_credits[i].name} '
                                    '(as ${_credits[i].creditedAs})',
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 200,
                          child: DropdownButtonFormField<CreditRole>(
                            isExpanded: true,
                            initialValue: _credits[i].role,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final role in CreditRole.values)
                                DropdownMenuItem(
                                  value: role,
                                  child: Text(creditRoleLabel(role)),
                                ),
                            ],
                            onChanged: _saving
                                ? null
                                : (value) => setState(() {
                                      if (value != null) {
                                        _credits[i] =
                                            _credits[i].withRole(value);
                                      }
                                    }),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          onPressed: _saving
                              ? null
                              : () => setState(() => _credits.removeAt(i)),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _addCredit() async {
    final picked = await pickArtist(
      context,
      ref,
      title: 'Add a credit to ${widget.edit.title}',
      exclude: {for (final credit in _credits) credit.artistId},
    );
    if (picked == null) return;
    setState(() {
      _credits = [
        ..._credits,
        CreditEdit(
          artistId: picked.id,
          name: picked.name,
          role: CreditRole.mainArtist,
        ),
      ];
    });
  }
}
