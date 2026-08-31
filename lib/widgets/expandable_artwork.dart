import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
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

  @override
  ConsumerState<ExpandableArtwork> createState() => _ExpandableArtworkState();
}

class _ExpandableArtworkState extends ConsumerState<ExpandableArtwork> {
  var _hovering = false;
  var _busy = false;

  Future<void> _change() async {
    // The filter is a convenience, not a guarantee: the store rejects whatever
    // it cannot decode, and that is what actually protects the library.
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
      final repository = ref.read(editRepositoryProvider);
      final path = File(file.path);
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
        onChange: widget.editable ? _change : null,
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
                      onTap: _busy ? null : _change,
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

    return Dialog(
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
                  Artwork(
                    storedPath: storedPath,
                    size: side,
                    borderRadius: 18,
                    fallbackSeed: title,
                    fallbackIcon: fallbackIcon,
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
    );
  }
}
