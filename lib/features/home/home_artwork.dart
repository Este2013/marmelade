import 'package:flutter/material.dart';

import '../../data/db/enums.dart';
import '../../domain/models/home_views.dart';
import '../../widgets/artwork.dart';

/// The picture on a home item.
///
/// Three cases in one widget because they have to agree pixel for pixel: a
/// single cover, a mosaic composed from a collection's contents, and the
/// placeholder when there is nothing to show. A collection whose contents have
/// covers gets a mosaic for free, so a tile somebody made by dragging four
/// albums together looks like those four albums without being told to.
///
/// The shape is the library's own vocabulary, not a decision taken here --
/// round for a person, a rounded square for everything else -- so a home page
/// never has to be learned separately from the rest of the app.
class HomeArtwork extends StatelessWidget {
  const HomeArtwork({
    super.key,
    required this.item,
    this.size,
    this.radius = 10,
  });

  final HomeItemView item;

  /// Side length, or null to fill the space given.
  final double? size;

  /// Corner radius for the square shapes. Ignored when the item is round.
  final double radius;

  /// Gap between mosaic cells, in logical pixels.
  ///
  /// Deliberately small: the mosaic should read as one picture made of four,
  /// not as four pictures that happen to be adjacent.
  static const _mosaicGap = 2.0;

  @override
  Widget build(BuildContext context) {
    final covers = item.coverPaths();
    final corner = item.kind.isRound ? 999.0 : radius;

    if (covers.length < 2) {
      return Artwork(
        storedPath: covers.isEmpty ? null : covers.first,
        size: size,
        borderRadius: corner,
        fallbackSeed: item.title,
        fallbackIcon: _iconFor(item.kind),
      );
    }

    // Artwork sizes itself; the mosaic is built from Expandeds and needs to
    // be told how big it is when it is not filling a slot already.
    final mosaic = _Mosaic(
      covers: covers,
      seed: item.title,
      icon: _iconFor(item.kind),
      radius: corner,
    );
    return size == null
        ? mosaic
        : SizedBox(width: size, height: size, child: mosaic);
  }

  /// What a tile shows when the thing it points at has no artwork anywhere.
  ///
  /// Keyed to the kind rather than one generic note: a placeholder that says
  /// which *sort* of thing is missing a picture is still telling the truth
  /// about the tile, which a music note on an artist is not.
  static IconData _iconFor(HomeItemKind kind) => switch (kind) {
        HomeItemKind.album => Icons.album_outlined,
        HomeItemKind.artist => Icons.person_outline,
        HomeItemKind.playlist => Icons.queue_music_outlined,
        HomeItemKind.track => Icons.music_note_outlined,
        HomeItemKind.collection => Icons.grid_view_outlined,
        HomeItemKind.query => Icons.search,
      };
}

/// Up to four covers laid out as one square.
///
/// Two covers split it in half rather than leaving two empty quarters: a
/// half-filled mosaic looks like a loading state, and a collection of two is a
/// perfectly ordinary thing to build.
class _Mosaic extends StatelessWidget {
  const _Mosaic({
    required this.covers,
    required this.seed,
    required this.icon,
    required this.radius,
  });

  final List<String> covers;
  final String seed;
  final IconData icon;
  final double radius;

  @override
  Widget build(BuildContext context) {
    const gap = HomeArtwork._mosaicGap;
    Widget cell(int index) => Artwork(
          storedPath: index < covers.length ? covers[index] : null,
          borderRadius: 0,
          fallbackSeed: '$seed$index',
          fallbackIcon: icon,
        );

    if (covers.length == 2) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Row(
          children: [
            Expanded(child: cell(0)),
            const SizedBox(width: gap),
            Expanded(child: cell(1)),
          ],
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: cell(0)),
                const SizedBox(width: gap),
                Expanded(child: cell(1)),
              ],
            ),
          ),
          const SizedBox(height: gap),
          Expanded(
            child: Row(
              children: [
                Expanded(child: cell(2)),
                const SizedBox(width: gap),
                Expanded(child: cell(3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
