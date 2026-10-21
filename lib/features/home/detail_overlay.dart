import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/enums.dart';
import '../library/album_detail_view.dart';
import '../library/artist_detail_view.dart';
import '../playlists/playlist_detail_view.dart';
import 'home_overlay.dart';

/// Opens an album, artist or playlist on top of whatever is already open.
///
/// The home page's own tiles still go to the full page, which is where
/// editing and the caption strip live. This is for the ones reached from
/// *inside* a collection: pushing those into the page behind put them under
/// the collection that was still open, so seeing what you clicked meant
/// closing the thing you clicked it from.
///
/// Recursive in the same way the collection panel is: an artist opened from
/// an album opened from a collection is a third panel, and closing them
/// walks back out the way you came in.
Future<void> showHomeDetail(
  BuildContext from, {
  required HomeItemKind kind,
  required int refId,
}) {
  return showHomeOverlay<void>(
    from,
    label: 'Close',
    builder: (context) => _DetailPanel(kind: kind, refId: refId),
  );
}

class _DetailPanel extends ConsumerWidget {
  const _DetailPanel({required this.kind, required this.refId});

  final HomeItemKind kind;
  final int refId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HomeOverlayCard(
      child: Stack(
        children: [
          // topInset zero: the page's own version leaves room for the
          // window's caption strip, and inside a panel there is none.
          Positioned.fill(child: _view(context)),
          Positioned(
            right: 8,
            top: 8,
            child: IconButton.filledTonal(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }

  Widget _view(BuildContext context) {
    // Every link inside opens another panel rather than the page behind,
    // which is the whole point: a stack you can walk back out of, instead of
    // one that quietly rearranges what is underneath.
    void open(HomeItemKind kind, int id) =>
        showHomeDetail(context, kind: kind, refId: id);

    switch (kind) {
      case HomeItemKind.album:
        return AlbumDetailView(
          albumId: refId,
          onOpenArtist: (id) => open(HomeItemKind.artist, id),
        );
      case HomeItemKind.artist:
        return ArtistDetailView(
          artistId: refId,
          onOpenAlbum: (id) => open(HomeItemKind.album, id),
          onOpenArtist: (id) => open(HomeItemKind.artist, id),
        );
      case HomeItemKind.playlist:
        return PlaylistDetailView(
          playlistId: refId,
          onBack: () => Navigator.of(context).pop(),
          onOpenPlaylist: (id) => open(HomeItemKind.playlist, id),
          onOpenArtist: (id) => open(HomeItemKind.artist, id),
          onOpenAlbum: (id) => open(HomeItemKind.album, id),
        );
      // Nothing else has a page to show: a collection opens its own panel,
      // and a track or a search is played rather than visited.
      case HomeItemKind.track:
      case HomeItemKind.collection:
      case HomeItemKind.query:
        return const SizedBox.shrink();
    }
  }
}
