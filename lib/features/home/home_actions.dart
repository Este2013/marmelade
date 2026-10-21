import 'package:flutter/widgets.dart';

import '../../data/db/enums.dart';
import '../../domain/models/home_views.dart';

/// What a home tile can do, handed down from the shell.
///
/// Gathered into one object rather than passed as six separate callbacks
/// because every level of the page needs the whole set: a section passes them
/// to a tile, a tile passes them to the overlay a collection opens, and that
/// overlay passes them to the tiles inside it. Threading six parameters
/// through three levels of recursion is how one of them quietly goes missing.
class HomeActions {
  const HomeActions({
    required this.openAlbum,
    required this.openArtist,
    required this.openPlaylist,
    required this.play,
    required this.openCollection,
  });

  final void Function(int albumId) openAlbum;
  final void Function(int artistId) openArtist;
  final void Function(int playlistId) openPlaylist;

  /// Queues and plays everything inside an item, whatever it is.
  final void Function(HomeItemView item) play;

  /// Expands a collection, from the tile the gesture started on.
  ///
  /// The context is the tile's own, so the animation can work out where on
  /// screen to grow from.
  final void Function(BuildContext from, HomeItemView collection) openCollection;

  /// The same actions with some of the destinations swapped.
  ///
  /// What the collection panel uses to send albums, artists and playlists to
  /// a panel on top instead of to the page behind it -- the page being
  /// exactly where they would land underneath the collection still open.
  HomeActions copyWith({
    void Function(int albumId)? openAlbum,
    void Function(int artistId)? openArtist,
    void Function(int playlistId)? openPlaylist,
  }) =>
      HomeActions(
        openAlbum: openAlbum ?? this.openAlbum,
        openArtist: openArtist ?? this.openArtist,
        openPlaylist: openPlaylist ?? this.openPlaylist,
        play: play,
        openCollection: openCollection,
      );

  /// Routes an item to whichever of the above it belongs to.
  ///
  /// A query has no page of its own to open -- it is a question, not a place
  /// -- so opening one plays it, which is the only thing it could mean.
  void open(BuildContext context, HomeItemView item) {
    switch (item.kind) {
      case HomeItemKind.album:
        if (item.refId != null) openAlbum(item.refId!);
      case HomeItemKind.artist:
        if (item.refId != null) openArtist(item.refId!);
      case HomeItemKind.playlist:
        if (item.refId != null) openPlaylist(item.refId!);
      case HomeItemKind.collection:
        openCollection(context, item);
      case HomeItemKind.track:
      case HomeItemKind.query:
        play(item);
    }
  }
}
