import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/enums.dart';
import '../../data/repositories/edit_repository.dart';
import '../../widgets/artwork.dart';
import 'edit_widgets.dart';

/// Picks a picture for an artist, album or track.
///
/// The store is content-addressed, so choosing a file already in the library
/// costs nothing on disk and cannot end up duplicated. Clearing detaches the
/// picture rather than deleting the file, which leaves the fallback chain --
/// track, then album, then artist -- to find the next one.
class PictureSection extends ConsumerStatefulWidget {
  const PictureSection({
    super.key,
    required this.imagePath,
    required this.fallbackSeed,
    required this.onPick,
    required this.onClear,
    this.subtitle,
    this.circular = false,
    this.fallbackIcon = Icons.album_outlined,
  });

  /// Path within the artwork store, or null when there is no picture.
  final String? imagePath;

  /// Seed for the placeholder colour, usually the name being edited.
  final String fallbackSeed;

  /// Stores the chosen file. Returns false when it could not be read.
  final Future<bool> Function(File file) onPick;

  final Future<void> Function() onClear;

  final String? subtitle;

  /// Artists read as portraits, releases as sleeves.
  final bool circular;

  final IconData fallbackIcon;

  @override
  ConsumerState<PictureSection> createState() => _PictureSectionState();
}

class _PictureSectionState extends ConsumerState<PictureSection> {
  var _busy = false;

  Future<void> _pick() async {
    // A picture chosen here is whatever the person points at, so the filter is
    // a convenience rather than a guarantee -- the store rejects anything it
    // cannot decode, and that is what actually protects the library.
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
        ),
      ],
    );
    if (file == null) return;

    setState(() => _busy = true);
    try {
      final ok = await widget.onPick(File(file.path));
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That file could not be read as an image.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    try {
      await widget.onClear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPicture = widget.imagePath != null;

    return EditSection(
      title: 'Picture',
      subtitle: widget.subtitle,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Artwork(
            storedPath: widget.imagePath,
            size: 120,
            borderRadius: widget.circular ? 60 : 10,
            fallbackSeed: widget.fallbackSeed,
            fallbackIcon: widget.fallbackIcon,
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasPicture
                      ? 'A picture chosen here wins over anything read out of '
                          'the files.'
                      : 'Nothing chosen. The picture shown comes from the '
                          'files, or from the album or artist above it.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _pick,
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: Text(hasPicture ? 'Replace' : 'Choose a picture'),
                    ),
                    if (hasPicture) ...[
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _clear,
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Remove'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A list of alternative names, with a field to add another.
///
/// Shared by artists, albums and tracks: the reason is the same in all three
/// cases -- a release or a song is often titled in one script on the sleeve and
/// another in the files, and both spellings should find it.
class AliasSection extends StatefulWidget {
  const AliasSection({
    super.key,
    required this.title,
    required this.subtitle,
    required this.aliases,
    required this.onAdd,
    required this.onRemove,
    this.emptyMessage = 'No other names yet.',
    this.addLabel = 'Add a name',
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final List<AliasRow> aliases;
  final Future<void> Function(String alias, AliasKind kind) onAdd;
  final Future<void> Function(int aliasId) onRemove;

  /// Shown in place of the chips when there are none.
  final String emptyMessage;

  final String addLabel;
  final bool enabled;

  @override
  State<AliasSection> createState() => _AliasSectionState();
}

class _AliasSectionState extends State<AliasSection> {
  final _controller = TextEditingController();
  var _kind = AliasKind.alias;
  var _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    await _run(() async {
      await widget.onAdd(text, _kind);
      _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.enabled && !_busy;

    return EditSection(
      title: widget.title,
      subtitle: widget.subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.aliases.isEmpty)
            Text(
              widget.emptyMessage,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final alias in widget.aliases)
                  Chip(
                    label: Text(alias.alias),
                    avatar: Tooltip(
                      message: aliasKindLabel(alias.kind),
                      child: const Icon(Icons.label_outline, size: 16),
                    ),
                    onDeleted: enabled
                        ? () => _run(() => widget.onRemove(alias.id))
                        : null,
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: EditField(
                  controller: _controller,
                  label: widget.addLabel,
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<AliasKind>(
                  isExpanded: true,
                  initialValue: _kind,
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
                  onChanged: (value) => setState(() => _kind = value ?? _kind),
                ),
              ),
              const SizedBox(width: 12),
              IconButton.filledTonal(
                tooltip: 'Add',
                onPressed: enabled ? _add : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
