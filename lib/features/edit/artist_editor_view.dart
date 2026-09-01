import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../data/repositories/edit_repository.dart';
import '../../data/repositories/tag_repository.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import 'edit_widgets.dart';
import 'picture_section.dart';
import 'tag_section.dart';

/// Everything about one artist that a person can change.
///
/// The library is read out of files, and files are wrong: names are misspelled,
/// the same person appears under two spellings, and a credit that should be two
/// artists arrived as one. This is where that gets corrected, and every change
/// made here marks the row verified so the next scan leaves it alone.
class ArtistEditorView extends ConsumerWidget {
  const ArtistEditorView({
    super.key,
    required this.artistId,
    required this.onBack,
    this.onOpenArtist,
  });

  final int artistId;
  final VoidCallback onBack;
  final void Function(int artistId)? onOpenArtist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = ref.watch(artistEditProvider(artistId));

    return artist.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load that artist',
        message: '$error',
      ),
      data: (edit) {
        if (edit == null) {
          return EmptyState(
            icon: Icons.person_off_outlined,
            title: 'That artist is gone',
            message: 'It was probably merged into another one, or removed when '
                'its last credit was split apart.',
            action: FilledButton(onPressed: onBack, child: const Text('Back')),
          );
        }
        return _Editor(
          key: ValueKey(edit.id),
          edit: edit,
          onBack: onBack,
          onOpenArtist: onOpenArtist,
        );
      },
    );
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({
    super.key,
    required this.edit,
    required this.onBack,
    this.onOpenArtist,
  });

  final ArtistEdit edit;
  final VoidCallback onBack;
  final void Function(int artistId)? onOpenArtist;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final TextEditingController _name;
  late final TextEditingController _sortName;
  late final TextEditingController _disambiguation;
  late final TextEditingController _description;
  final _newAlias = TextEditingController();

  late ArtistKind _kind;
  late bool _neverSplit;
  var _aliasKind = AliasKind.alias;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    final edit = widget.edit;
    _name = TextEditingController(text: edit.name);
    _sortName = TextEditingController(text: edit.sortName ?? '');
    _disambiguation = TextEditingController(text: edit.disambiguation ?? '');
    _description = TextEditingController(text: edit.description ?? '');
    _kind = edit.kind;
    _neverSplit = edit.neverSplit;
    for (final controller in [
      _name,
      _sortName,
      _disambiguation,
      _description,
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
    _name.dispose();
    _sortName.dispose();
    _disambiguation.dispose();
    _description.dispose();
    _newAlias.dispose();
    super.dispose();
  }

  EditRepository get _repository => ref.read(editRepositoryProvider);

  /// True when the form differs from what is stored.
  bool get _dirty {
    final edit = widget.edit;
    return _name.text.trim() != edit.name ||
        _sortName.text.trim() != (edit.sortName ?? '') ||
        _disambiguation.text.trim() != (edit.disambiguation ?? '') ||
        _description.text.trim() != (edit.description ?? '') ||
        _kind != edit.kind ||
        _neverSplit != edit.neverSplit;
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await action();
      if (mounted && done != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(done), duration: const Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() => _run(
        () => _repository.saveArtist(
          widget.edit.id,
          name: _name.text,
          sortName: _sortName.text,
          kind: _kind,
          disambiguation: _disambiguation.text,
          description: _description.text,
          neverSplit: _neverSplit,
        ),
        done: 'Saved',
      );

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
                borderRadius: 20,
                fallbackSeed: edit.name,
                fallbackIcon: edit.isGroup
                    ? Icons.groups_outlined
                    : Icons.person_outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(edit.name, style: theme.textTheme.titleLarge),
                    Text(
                      '${pluralize(edit.trackCount, 'track')}'
                      '${edit.isVerified ? ' · reviewed' : ''}',
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
                  _identity(),
                  PictureSection(
                    imagePath: edit.imagePath,
                    fallbackSeed: edit.name,
                    circular: true,
                    fallbackIcon: edit.isGroup
                        ? Icons.groups_outlined
                        : Icons.person_outline,
                    subtitle: 'A portrait for this artist. Tracks and albums '
                        'with no picture of their own fall back to it.',
                    onPick: (file) =>
                        _repository.setArtistPicture(edit.id, file),
                    onClear: () => _repository.clearArtistPicture(edit.id),
                  ),
                  _aliases(edit),
                  if (edit.isGroup || edit.members.isNotEmpty) _members(edit),
                  _partOf(edit),
                  TagSection(target: TagTarget.artist, id: edit.id),
                  _structure(edit),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------------------------- identity

  Widget _identity() {
    return EditSection(
      title: 'Name',
      subtitle: 'The name shown everywhere. Changing it also changes what file '
          'metadata is matched against, so a rescan keeps finding this artist.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              EditField(controller: _name, label: 'Name', width: 320),
              EditField(
                controller: _sortName,
                label: 'Sort name',
                hint: 'Beatles, The',
                width: 240,
              ),
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<ArtistKind>(
                  isExpanded: true,
                  initialValue: _kind,
                  decoration: const InputDecoration(
                    labelText: 'Kind',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final kind in ArtistKind.values)
                      DropdownMenuItem(
                        value: kind,
                        child: Text(artistKindLabel(kind)),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _kind = value ?? _kind),
                ),
              ),
              EditField(
                controller: _disambiguation,
                label: 'Disambiguation',
                hint: 'UK punk band',
                width: 240,
              ),
            ],
          ),
          const SizedBox(height: 16),
          EditField(
            controller: _description,
            label: 'Notes',
            hint: 'Markdown is fine.',
            maxLines: 5,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _neverSplit,
            onChanged: (value) => setState(() => _neverSplit = value),
            title: const Text('Never split this name'),
            subtitle: const Text(
              'For a name that contains what looks like a separator and is '
              'nonetheless one artist: AC/DC, Earth, Wind & Fire.',
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ aliases

  Widget _aliases(ArtistEdit edit) {
    return EditSection(
      title: 'Other names',
      subtitle: 'Alternative spellings that should find this artist. A native '
          'script name, a romanisation, an abbreviation, or just what the '
          'files happen to say.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (edit.aliases.isEmpty)
            _empty('No other names yet.')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final alias in edit.aliases)
                  Chip(
                    label: Text(alias.alias),
                    avatar: Tooltip(
                      message: aliasKindLabel(alias.kind),
                      child: const Icon(Icons.label_outline, size: 16),
                    ),
                    onDeleted: _saving
                        ? null
                        : () => _run(
                              () => _repository.removeArtistAlias(alias.id),
                            ),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: EditField(
                  controller: _newAlias,
                  label: 'Add a name',
                  onSubmitted: (_) => _addAlias(),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<AliasKind>(
                  isExpanded: true,
                  initialValue: _aliasKind,
                  decoration: const InputDecoration(
                    labelText: 'Kind',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final kind in AliasKind.values)
                      DropdownMenuItem(
                        value: kind,
                        child: Text(aliasKindLabel(kind)),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _aliasKind = value ?? _aliasKind),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                tooltip: 'Add',
                onPressed: _saving ? null : _addAlias,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _addAlias() async {
    final text = _newAlias.text.trim();
    if (text.isEmpty) return;
    await _run(() async {
      await _repository.addArtistAlias(
        widget.edit.id,
        text,
        kind: _aliasKind,
      );
      _newAlias.clear();
    });
  }

  // ------------------------------------------------------------------ members

  Widget _members(ArtistEdit edit) {
    return EditSection(
      title: 'Members',
      subtitle: 'Who is in this group. Each member stays an artist in their own '
          'right, with their own page and their own tracks.',
      trailing: FilledButton.tonalIcon(
        onPressed: _saving ? null : _addMember,
        icon: const Icon(Icons.person_add_outlined, size: 18),
        label: const Text('Add member'),
      ),
      child: edit.members.isEmpty
          ? _empty('No members recorded.')
          : Column(
              children: [
                for (final member in edit.members)
                  _MembershipTile(
                    row: member,
                    onOpen: widget.onOpenArtist,
                    onRemove: _saving
                        ? null
                        : () =>
                            _run(() => _repository.removeMember(member.id)),
                  ),
              ],
            ),
    );
  }

  Future<void> _addMember() async {
    final edit = widget.edit;
    final picked = await pickArtist(
      context,
      ref,
      title: 'Add a member to ${edit.name}',
      // Neither itself nor anyone already in it.
      exclude: {edit.id, ...edit.members.map((m) => m.artistId)},
    );
    if (picked == null) return;

    final role = await _askForText(
      title: 'Role of ${picked.name}',
      hint: 'Vocals, guitar, composer... (optional)',
    );
    // A dismissed role prompt still means "add them", just without a role.
    await _run(
      () => _repository.addMember(edit.id, picked.id, role: role),
      done: '${picked.name} added',
    );
  }

  Widget _partOf(ArtistEdit edit) {
    return EditSection(
      title: 'Part of',
      subtitle: 'Groups this artist belongs to.',
      trailing: FilledButton.tonalIcon(
        onPressed: _saving ? null : _addToGroup,
        icon: const Icon(Icons.group_add_outlined, size: 18),
        label: const Text('Add to a group'),
      ),
      child: edit.memberOf.isEmpty
          ? _empty('Not recorded as part of any group.')
          : Column(
              children: [
                for (final group in edit.memberOf)
                  _MembershipTile(
                    row: group,
                    onOpen: widget.onOpenArtist,
                    onRemove: _saving
                        ? null
                        : () => _run(() => _repository.removeMember(group.id)),
                  ),
              ],
            ),
    );
  }

  Future<void> _addToGroup() async {
    final edit = widget.edit;
    final picked = await pickArtist(
      context,
      ref,
      title: 'Add ${edit.name} to a group',
      exclude: {edit.id, ...edit.memberOf.map((m) => m.artistId)},
    );
    if (picked == null) return;
    await _run(
      () => _repository.addMember(picked.id, edit.id),
      done: 'Added to ${picked.name}',
    );
  }

  // ---------------------------------------------------------------- structure

  Widget _structure(ArtistEdit edit) {
    final scheme = Theme.of(context).colorScheme;

    return EditSection(
      title: 'Split or merge',
      subtitle: 'Both of these rewrite every credit this artist has, across the '
          'whole library.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.call_split, color: scheme.primary),
            title: const Text('Split into several artists'),
            subtitle: Text(
              'For a name that is really two or more people, like '
              '"LukHash x Shirobon". Every track credited to '
              '${edit.name} will be credited to each of them instead.',
            ),
            trailing: OutlinedButton(
              onPressed: _saving ? null : _split,
              child: const Text('Split'),
            ),
          ),
          const Divider(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.merge, color: scheme.primary),
            title: const Text('Merge another artist into this one'),
            subtitle: const Text(
              'For the same artist under two spellings. The other name is kept '
              'as an alias, so searching it still finds these tracks.',
            ),
            trailing: OutlinedButton(
              onPressed: _saving ? null : _merge,
              child: const Text('Merge'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _split() async {
    final names = await showDialog<List<String>>(
      context: context,
      builder: (context) => _SplitDialog(name: widget.edit.name),
    );
    if (names == null || names.length < 2) return;

    final created = await _repository.splitArtist(widget.edit.id, names);
    if (!mounted) return;
    if (created.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Split into ${names.join(', ')}')),
    );
    // This artist may well be gone now, so there is nothing left to edit.
    widget.onBack();
  }

  Future<void> _merge() async {
    final edit = widget.edit;
    final picked = await pickArtist(
      context,
      ref,
      title: 'Merge into ${edit.name}',
      exclude: {edit.id},
    );
    if (picked == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Merge ${picked.name} into ${edit.name}?'),
        content: Text(
          '${pluralize(picked.trackCount, 'track')} will be re-credited to '
          '${edit.name}. "${picked.name}" is kept as an alias, so searching it '
          'still finds them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _run(
      () => _repository.mergeArtists(edit.id, [picked.id]),
      done: '${picked.name} merged into ${edit.name}',
    );
  }

  // ------------------------------------------------------------------ helpers

  Widget _empty(String message) => Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      );

  Future<String?> _askForText({
    required String title,
    String? hint,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

/// One member or group, with a way to open it and a way to remove it.
class _MembershipTile extends StatelessWidget {
  const _MembershipTile({required this.row, this.onOpen, this.onRemove});

  final MembershipRow row;
  final void Function(int artistId)? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        row.kind == ArtistKind.group || row.kind == ArtistKind.orchestra
            ? Icons.groups_outlined
            : Icons.person_outline,
      ),
      title: Text(row.name),
      subtitle: Text(
        [
          if (row.role != null) row.role!,
          pluralize(row.trackCount, 'track'),
        ].join(' · '),
      ),
      onTap: onOpen == null ? null : () => onOpen!(row.artistId),
      trailing: IconButton(
        tooltip: 'Remove',
        onPressed: onRemove,
        icon: const Icon(Icons.close, size: 18),
      ),
    );
  }
}

/// Asks for the names an artist should be split into.
class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.name});

  final String name;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    // Pre-filled with the obvious guess. Most composites arrived as
    // "A <separator> B", so offering the pieces saves retyping them.
    final guess = _guessParts(widget.name);
    _controllers = [
      for (final part in guess) TextEditingController(text: part),
    ];
  }

  /// Splits on the separators that usually mean "and", for a first guess.
  ///
  /// Only a suggestion -- the fields are editable, and the resolver's own
  /// rules are not reused here because this is exactly the case where they
  /// declined to decide.
  static List<String> _guessParts(String name) {
    final parts = name
        .split(RegExp(r'\s*(?:[×✕✖,;/&+|]|\bx\b|\bvs\.?\b|\band\b)\s*',
            caseSensitive: false))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    // Two empty fields is a better starting point than one prefilled with the
    // whole composite, which is what a name with no separator would give.
    return parts.length >= 2 ? parts : [name, ''];
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Split ${widget.name}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Every track credited to this name will be credited to each of '
              'these instead. An existing artist with the same name is reused '
              'rather than duplicated.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < _controllers.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controllers[i],
                        autofocus: i == 0,
                        decoration: InputDecoration(
                          labelText: 'Artist ${i + 1}',
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (_controllers.length > 2)
                      IconButton(
                        tooltip: 'Remove',
                        onPressed: () => setState(() {
                          _controllers.removeAt(i).dispose();
                        }),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: () => setState(
                () => _controllers.add(TextEditingController()),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Another artist'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final names = [
              for (final controller in _controllers)
                if (controller.text.trim().isNotEmpty) controller.text.trim(),
            ];
            Navigator.of(context).pop(names);
          },
          child: const Text('Split'),
        ),
      ],
    );
  }
}
