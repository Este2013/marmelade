import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/edit_repository.dart';
import '../../widgets/artwork.dart';
import 'edit_widgets.dart';
import 'picture_section.dart';

/// The picture section for a track: three cards, one per stage of
/// `v_track_artwork`'s own fallback (see database.dart), with the stage that
/// actually wins highlighted.
///
/// Ordered artist first, track last -- the same direction the fallback
/// itself runs backwards through, from "whoever is ultimately responsible"
/// down to "the one specific thing that overrides them". Only the track's
/// own stage is editable here -- a picture chosen for the album or the
/// artist belongs on their own editors, so those two cards push that page
/// instead.
class TrackArtworkChainSection extends ConsumerStatefulWidget {
  const TrackArtworkChainSection({super.key, required this.trackId, required this.trackTitle, this.onOpenAlbum, this.onOpenArtist});

  final int trackId;
  final String trackTitle;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int artistId)? onOpenArtist;

  @override
  ConsumerState<TrackArtworkChainSection> createState() => _TrackArtworkChainSectionState();
}

class _TrackArtworkChainSectionState extends ConsumerState<TrackArtworkChainSection> {
  var _busy = false;

  Future<void> _pickTrackPicture() async {
    if (_busy) return;
    final file = await pickImageFile();
    if (file == null) return;

    setState(() => _busy = true);
    try {
      final ok = await ref.read(editRepositoryProvider).setTrackPicture(widget.trackId, file);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That file could not be read as an image.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearTrackPicture() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(editRepositoryProvider).clearTrackPicture(widget.trackId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chain = ref.watch(trackArtworkChainProvider(widget.trackId)).value;
    final stage = chain?.resolvedStage ?? ArtworkStage.none;

    return EditSection(
      title: 'Picture',
      subtitle: switch (stage) {
        ArtworkStage.track =>
          'This track has its own picture, which wins over the album and '
              'the artist.',
        ArtworkStage.album => "This track has no picture of its own, so the album's is shown.",
        ArtworkStage.artist =>
          "Neither this track nor its album has a picture, so the artist's "
              'is shown.',
        ArtworkStage.none => 'Nothing to show yet, at any stage.',
      },
      child: Row(
        spacing: 8,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: _StageCard(
              label: 'Artist',
              name: chain?.artistName,
              imagePath: chain?.artistImagePath,
              fallbackIcon: Icons.person_outline,
              circular: true,
              highlighted: stage == ArtworkStage.artist,
              hoverIcon: Icons.open_in_new,
              onTap: chain?.artistId == null || widget.onOpenArtist == null ? null : () => widget.onOpenArtist!(chain!.artistId!),
            ),
          ),
          const _Arrow(),
          Expanded(
            child: _StageCard(
              label: 'Album',
              name: chain?.albumTitle,
              imagePath: chain?.albumImagePath,
              fallbackIcon: Icons.album_outlined,
              highlighted: stage == ArtworkStage.album,
              hoverIcon: Icons.open_in_new,
              onTap: chain?.albumId == null || widget.onOpenAlbum == null ? null : () => widget.onOpenAlbum!(chain!.albumId!),
            ),
          ),
          const _Arrow(),
          Expanded(
            child: _StageCard(
              label: 'Track',
              name: widget.trackTitle,
              imagePath: chain?.trackImagePath,
              fallbackIcon: Icons.music_note_outlined,
              highlighted: stage == ArtworkStage.track,
              hoverIcon: Icons.edit,
              onTap: _busy ? null : _pickTrackPicture,
              secondaryIcon: chain?.trackImagePath == null ? null : Icons.delete_outline,
              onSecondaryTap: _busy ? null : _clearTrackPicture,
            ),
          ),
        ],
      ),
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow();

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.arrow_forward, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant);
  }
}

/// One stage of the fallback: what it is, its own picture (not the resolved
/// one), and whether it is the stage actually winning.
///
/// [onTap] doubles as the action behind the hover button: for the album and
/// the artist that opens their own page, for the track it opens the file
/// picker directly, since there is nowhere else for that one to go.
class _StageCard extends StatefulWidget {
  const _StageCard({
    required this.label,
    required this.imagePath,
    required this.fallbackIcon,
    required this.highlighted,
    required this.hoverIcon,
    this.name,
    this.circular = false,
    this.onTap,
    this.secondaryIcon,
    this.onSecondaryTap,
  });

  final String label;
  final String? name;
  final String? imagePath;
  final IconData fallbackIcon;
  final bool circular;
  final bool highlighted;
  final IconData hoverIcon;
  final VoidCallback? onTap;

  /// A second hover button, top-right of the card -- only the track card has
  /// one, to remove a picture it actually has. Null hides it entirely.
  final IconData? secondaryIcon;
  final VoidCallback? onSecondaryTap;

  @override
  State<_StageCard> createState() => _StageCardState();
}

class _StageCardState extends State<_StageCard> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const artSize = 84.0;

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: widget.highlighted ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
        border: Border.all(color: widget.highlighted ? scheme.primary : scheme.outlineVariant, width: widget.highlighted ? 2 : 1),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: .center,
        children: [
          Column(
            crossAxisAlignment: .center,
            children: [
              Artwork(storedPath: widget.imagePath, size: artSize, borderRadius: widget.circular ? artSize / 2 : 8, fallbackSeed: widget.name ?? widget.label, fallbackIcon: widget.fallbackIcon),

              const SizedBox(height: 8),
              Text(
                widget.label,
                style: theme.textTheme.labelMedium?.copyWith(color: widget.highlighted ? scheme.primary : scheme.onSurfaceVariant, fontWeight: widget.highlighted ? FontWeight.w600 : null),
              ),
              Text(widget.name ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            ],
          ), // Faded rather than removed while not hovered, the same reason
          // every other hover-revealed control in this app stays in the
          // tree: an appearing widget churns the accessibility tree, and
          // this one is reachable by a screen reader either way.
          if (widget.secondaryIcon != null)
            Positioned.directional(
              end: -6,
              top: -6,
              textDirection: .ltr,

              child: AnimatedOpacity(
                opacity: _hovering && widget.onSecondaryTap != null ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                alwaysIncludeSemantics: true,
                child: FloatingActionButton.small(heroTag: null, onPressed: widget.onSecondaryTap, child: Icon(widget.secondaryIcon, size: 18)),
              ),
            ),
          Positioned(
            right: -6,
            bottom: -6,
            child: AnimatedOpacity(
              opacity: _hovering && widget.onTap != null ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              alwaysIncludeSemantics: true,
              child: FloatingActionButton.small(heroTag: null, onPressed: widget.onTap, child: Icon(widget.hoverIcon, size: 18)),
            ),
          ),
        ],
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: widget.onTap == null ? card : InkWell(onTap: widget.onTap, borderRadius: BorderRadius.circular(12), child: card),
    );
  }
}
