import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import 'home_drag.dart';

/// Makes anything in the library pickable up and droppable on the home page.
///
/// Wrapped around a tile or row wherever one is shown -- the albums grid, the
/// artists grid, every track list, the playlist list -- so "put this on my
/// home page" is the same gesture everywhere rather than a menu item each of
/// those would have to grow separately.
///
/// Long press rather than plain drag, and that is the whole reason this is
/// safe to apply so widely: a grid already uses press-and-move for scrolling
/// and click for opening, and neither changes. Only a deliberate hold starts
/// a drag.
class LibraryDraggable extends ConsumerWidget {
  const LibraryDraggable({
    super.key,
    required this.kind,
    required this.refId,
    required this.title,
    required this.child,
  });

  final HomeItemKind kind;
  final int refId;
  final String title;
  final Widget child;

  static IconData _iconFor(HomeItemKind kind) => switch (kind) {
        HomeItemKind.album => Icons.album_outlined,
        HomeItemKind.artist => Icons.person_outline,
        HomeItemKind.playlist => Icons.queue_music_outlined,
        HomeItemKind.track => Icons.music_note_outlined,
        HomeItemKind.collection => Icons.grid_view_outlined,
        HomeItemKind.query => Icons.search,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payload = HomeAdd(kind: kind, refId: refId, title: title);

    return LongPressDraggable<HomeDrag>(
      data: payload,
      delay: const Duration(milliseconds: 220),
      // See the note in home_drag.dart: a DragTargetDetails.offset is the
      // feedback's top-left, and the home page's before-or-into decision
      // reads it as though it were the pointer.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: HomeDragPreview(title: title, icon: _iconFor(kind)),
      // Announced so the home button can light up and the section gaps can
      // open, both of which have to happen in parts of the tree nowhere near
      // the thing being dragged.
      onDragStarted: () =>
          ref.read(homeDragProvider.notifier).start(payload),
      onDragEnd: (_) => ref.read(homeDragProvider.notifier).stop(),
      onDraggableCanceled: (_, _) =>
          ref.read(homeDragProvider.notifier).stop(),
      // Unlike the home page's own tiles, the original stays at full
      // strength: the library list is not being rearranged, and fading a row
      // would suggest it was about to leave.
      child: child,
    );
  }
}
