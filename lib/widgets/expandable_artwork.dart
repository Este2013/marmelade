import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/logging/app_log.dart';
import '../data/repositories/edit_repository.dart' show LinkRow;
import '../features/edit/link_visuals.dart';
import '../services/art/link_artwork_service.dart';
import 'artwork.dart';

/// What a picture belongs to.
enum PictureOwner { artist, album, track, playlist }

/// The artwork on a detail page: click to see it big, hover to change it.
///
/// Two jobs that belong together. The picture is the biggest thing on these
/// pages and it was the one thing you could not do anything with -- looking at
/// it properly meant opening the file, and changing it meant going to the
/// editor and finding the right section.
class ExpandableArtwork extends ConsumerStatefulWidget {
  const ExpandableArtwork({
    super.key,
    required this.storedPath,
    required this.size,
    required this.owner,
    required this.id,
    required this.title,
    this.borderRadius = 14,
    this.fallbackIcon = Icons.album_outlined,
    this.heroTag,
    this.editable = true,
    this.pickFromCovers = const [],
    this.pickFromLinks = const [],
  });

  final String? storedPath;
  final double size;

  final PictureOwner owner;
  final int id;

  /// Named in the preview, and used to seed the placeholder colour.
  final String title;

  final double borderRadius;
  final IconData fallbackIcon;
  final String? heroTag;

  /// False where there is nothing to change -- a synthetic single, say.
  final bool editable;

  /// Covers already on hand to choose from instead of browsing for a file --
  /// a playlist's own tracks' album art, say. Offered as a grid ahead of the
  /// file browser rather than instead of it: picking one is the fast path,
  /// browsing is still there for anything the playlist does not already
  /// carry.
  final List<String> pickFromCovers;

  /// Pages that might already show a picture of this thing -- an artist's own
  /// links. Same idea as [pickFromCovers] one step further out: the library
  /// knows where this artist lives on the internet, so the photo is usually a
  /// fetch away rather than something to go and find and save first.
  final List<LinkRow> pickFromLinks;

  @override
  ConsumerState<ExpandableArtwork> createState() => _ExpandableArtworkState();
}

class _ExpandableArtworkState extends ConsumerState<ExpandableArtwork> {
  var _hovering = false;
  var _busy = false;

  /// Opens the picker: whatever is already on hand -- covers from a
  /// playlist's own tracks, pages an artist links to -- plus a way to browse
  /// for a file. Straight to the file browser when there is nothing on hand,
  /// since a dialog with one button in it is a dialog for nothing.
  Future<void> _openPicker() async {
    if (widget.pickFromCovers.isEmpty && widget.pickFromLinks.isEmpty) {
      await _change();
      return;
    }
    final choice = await showDialog<_CoverChoice>(
      context: context,
      builder: (context) => _CoverPickerDialog(
        covers: widget.pickFromCovers,
        links: widget.pickFromLinks,
      ),
    );
    if (choice == null) return;
    switch (choice) {
      case _BrowseChoice():
        await _change();
      case _ExistingChoice(:final storedPath):
        await _pickExisting(storedPath);
      case _LinkChoice(:final link):
        await _pickFromLink(link);
    }
  }

  /// Fetches whatever picture [link]'s page shows for itself.
  ///
  /// Reports its own failures on screen rather than silently doing nothing:
  /// this reaches the network, so "the site refused" and "there is no picture
  /// there" are ordinary outcomes and the person needs to know which, to
  /// decide whether to try another link or go and find a file.
  Future<void> _pickFromLink(LinkRow link) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result =
          await ref.read(linkArtworkServiceProvider).fetch(link.url);
      if (!mounted) return;

      switch (result) {
        case LinkArtworkMissing(:final reason):
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(reason)));
        case LinkArtworkFound(:final bytes, :final page):
          final repository = ref.read(editRepositoryProvider);
          final source = result.describe();
          final ok = switch (widget.owner) {
            PictureOwner.artist => await repository.setArtistPictureFromBytes(
                widget.id, bytes, source: source),
            PictureOwner.album => await repository.setAlbumPictureFromBytes(
                widget.id, bytes, source: source),
            PictureOwner.track => await repository.setTrackPictureFromBytes(
                widget.id, bytes, source: source),
            PictureOwner.playlist =>
              await repository.setPlaylistPictureFromBytes(
                  widget.id, bytes, source: source),
          };
          AppLog.instance.info('picture set from a link', fields: {
            ..._where,
            'page': '$page',
            'accepted': ok,
          });
          if (!mounted) return;
          if (!ok) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'What ${page.host} offered could not be read as an image.',
                ),
              ),
            );
          }
      }
    } catch (error, stack) {
      AppLog.instance.error(
        'picture from a link failed',
        error: error,
        stack: stack,
        fields: {..._where, 'url': link.url},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That picture could not be set.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change() async {
    // Held across the picker too, not just the write that follows it.
    //
    // The Windows file dialog is modal to the whole app, and asking for a
    // second one while the first is open wedges it: no error, no log, nothing
    // on screen -- the app simply stops. A double-click on a small button is
    // enough to do it.
    if (_busy) {
      AppLog.instance.warn('picture picker already open', fields: _where);
      return;
    }
    setState(() => _busy = true);

    try {
      AppLog.instance.info('picture picker opening', fields: _where);
      // The filter is a convenience, not a guarantee: the store rejects
      // whatever it cannot decode, and that is what actually protects the
      // library.
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Images',
            extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
          ),
        ],
      );
      AppLog.instance.info('picture picker closed', fields: {
        ..._where,
        'picked': file?.path,
      });
      if (file == null) return;
      await _apply(File(file.path));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reuses a cover already stored for one of the playlist's own tracks.
  ///
  /// The store is content-addressed (see `ArtStore`), so pointing the
  /// playlist at a file it already holds costs nothing on disk and cannot end
  /// up duplicated -- this is the same write [_change] does, just fed a file
  /// that was never browsed for.
  Future<void> _pickExisting(String storedPath) async {
    if (_busy) {
      AppLog.instance.warn('picture picker already open', fields: _where);
      return;
    }
    setState(() => _busy = true);
    try {
      final file = ref.read(artStoreProvider).fileFor(storedPath);
      await _apply(file);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Writes [path] as this thing's picture. Assumes [_busy] is already set by
  /// the caller, which is what keeps a second picker from opening mid-write.
  Future<void> _apply(File path) async {
    try {
      final repository = ref.read(editRepositoryProvider);
      final ok = switch (widget.owner) {
        PictureOwner.artist => await repository.setArtistPicture(
            widget.id,
            path,
          ),
        PictureOwner.album => await repository.setAlbumPicture(widget.id, path),
        PictureOwner.track => await repository.setTrackPicture(widget.id, path),
        PictureOwner.playlist => await repository.setPlaylistPicture(
            widget.id,
            path,
          ),
      };
      AppLog.instance.info('picture set', fields: {..._where, 'accepted': ok});
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That file could not be read as an image.'),
          ),
        );
      }
    } catch (error, stack) {
      // Logged rather than swallowed: this runs from a button that otherwise
      // just stops working, and a failure with no trace of it is the hardest
      // kind to chase.
      AppLog.instance.error(
        'picture change failed',
        error: error,
        stack: stack,
        fields: _where,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That picture could not be set.')),
        );
      }
    }
  }

  /// What the log lines are about, so a freeze names its own button.
  Map<String, Object?> get _where => {
        'owner': widget.owner.name,
        'id': widget.id,
        'title': widget.title,
      };

  Future<void> _clear() async {
    final repository = ref.read(editRepositoryProvider);
    switch (widget.owner) {
      case PictureOwner.artist:
        await repository.clearArtistPicture(widget.id);
      case PictureOwner.album:
        await repository.clearAlbumPicture(widget.id);
      case PictureOwner.track:
        await repository.clearTrackPicture(widget.id);
      case PictureOwner.playlist:
        await repository.clearPlaylistPicture(widget.id);
    }
  }

  void _expand() {
    showDialog<void>(
      context: context,
      // Barrier rather than a route: the point is to look at the picture over
      // the page, not to navigate somewhere.
      barrierColor: Colors.black.withValues(alpha: 0.86),
      builder: (context) => _PreviewOverlay(
        storedPath: widget.storedPath,
        title: widget.title,
        fallbackIcon: widget.fallbackIcon,
        onChange: widget.editable ? _openPicker : null,
        onClear: widget.editable && widget.storedPath != null ? _clear : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: Stack(
        children: [
          GestureDetector(
            onTap: _expand,
            child: Artwork(
              storedPath: widget.storedPath,
              size: widget.size,
              borderRadius: widget.borderRadius,
              fallbackSeed: widget.title,
              fallbackIcon: widget.fallbackIcon,
              heroTag: widget.heroTag,
            ),
          ),
          if (widget.editable)
            Positioned(
              right: 8,
              bottom: 8,
              child: AnimatedOpacity(
                opacity: _hovering ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                // Kept in the tree at zero opacity. Adding and removing an
                // interactive node on every hover is what floods the Windows
                // accessibility bridge, and a screen reader should reach this
                // without needing a pointer.
                alwaysIncludeSemantics: true,
                child: Tooltip(
                  message: 'Change the picture',
                  child: Material(
                    color: scheme.primaryContainer,
                    shape: const CircleBorder(),
                    elevation: 3,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _busy ? null : _openPicker,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: _busy
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.onPrimaryContainer,
                                ),
                              )
                            : Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: scheme.onPrimaryContainer,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The picture, as big as the window allows.
class _PreviewOverlay extends StatelessWidget {
  const _PreviewOverlay({
    required this.storedPath,
    required this.title,
    required this.fallbackIcon,
    this.onChange,
    this.onClear,
  });

  final String? storedPath;
  final String title;
  final IconData fallbackIcon;
  final VoidCallback? onChange;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The whole surface dismisses, not just the barrier outside the dialog.
    // The dialog is mostly empty space around a square picture, and clicking
    // that space is indistinguishable from clicking the barrier -- so it has to
    // do the same thing.
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      behavior: HitTestBehavior.opaque,
      child: Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(32),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Square, bounded by whichever axis runs out first, and never
          // enlarged past what the window can show.
          final side = (constraints.maxHeight - 110)
              .clamp(160.0, constraints.maxWidth)
              .toDouble();

          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                children: [
                  // Absorbs the tap: clicking the picture is looking at it, not
                  // dismissing it.
                  GestureDetector(
                    onTap: () {},
                    child: Artwork(
                      storedPath: storedPath,
                      size: side,
                      borderRadius: 18,
                      fallbackSeed: title,
                      fallbackIcon: fallbackIcon,
                    ),
                  ),
                  if (onChange != null)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: FloatingActionButton.extended(
                        onPressed: () {
                          Navigator.of(context).pop();
                          onChange!();
                        },
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('Change the picture'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge
                    ?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (onClear != null)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        onClear!();
                      },
                      icon: const Icon(Icons.hide_image_outlined, size: 18),
                      label: const Text('Remove it'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                      ),
                    ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Close'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
        ),
      ),
    );
  }
}

/// What the picker was asked for.
sealed class _CoverChoice {
  const _CoverChoice();
}

class _ExistingChoice extends _CoverChoice {
  const _ExistingChoice(this.storedPath);
  final String storedPath;
}

class _BrowseChoice extends _CoverChoice {
  const _BrowseChoice();
}

class _LinkChoice extends _CoverChoice {
  const _LinkChoice(this.link);
  final LinkRow link;
}

/// What is already on hand -- covers from the playlist's own tracks, pages
/// the artist links to -- with a way to browse for a file instead.
class _CoverPickerDialog extends StatelessWidget {
  const _CoverPickerDialog({this.covers = const [], this.links = const []});

  final List<String> covers;
  final List<LinkRow> links;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return AlertDialog(
      title: const Text('Choose a picture'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              switch ((covers.isNotEmpty, links.isNotEmpty)) {
                (true, true) =>
                  'From a cover already here, from one of the links, or '
                      'browse for a file.',
                (false, true) =>
                  'Try one of this artist\'s own pages, or browse for a file.',
                _ => 'From a cover already in this playlist, or browse for a '
                    'file.',
              },
              style: muted,
            ),
            if (links.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final link in links)
                    // The site's own badge on the button: which page a photo
                    // comes from is the whole decision being made here, and
                    // "Bandcamp" and "YouTube" are not interchangeable.
                    ActionChip(
                      avatar: LinkKindIcon(kind: link.kind, size: 18),
                      label: Text(link.label ?? linkKindLabel(link.kind)),
                      onPressed: () =>
                          Navigator.of(context).pop(_LinkChoice(link)),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Fetches whatever picture that page shows for itself.',
                  style: muted,
                ),
              ),
            ],
            if (covers.isNotEmpty) ...[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final cover in covers)
                        _CoverTile(
                          storedPath: cover,
                          onTap: () => Navigator.of(context)
                              .pop(_ExistingChoice(cover)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(const _BrowseChoice()),
          icon: const Icon(Icons.folder_open_outlined, size: 18),
          label: const Text('Browse for a file...'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _CoverTile extends StatelessWidget {
  const _CoverTile({required this.storedPath, required this.onTap});

  final String storedPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Artwork(storedPath: storedPath, size: 72, borderRadius: 8),
        ),
      ),
    );
  }
}
