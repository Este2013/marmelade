import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/db/enums.dart' show QueueSource;
import 'title_with_actions.dart';

/// How far a detail page travels before its title row counts as gone.
///
/// Roughly the height of a name-and-controls row: past this the title and the
/// play buttons have left the screen, which is the moment the caption strip
/// has to take them over. A constant rather than the widget's real height,
/// which is not known until it has been laid out and varies with how much
/// each page has to say about itself.
const detailCollapseAfter = 100.0;

/// Tells the caption strip when this page has scrolled past its title row.
///
/// The page owns the scroll and the shell builds the strip, so the two are
/// siblings that cannot see each other; they share a flag instead. Wrap the
/// page's scrollable in this, and have its chrome read
/// [detailHeaderCollapsedProvider].
class CollapsingHeader extends ConsumerStatefulWidget {
  const CollapsingHeader({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CollapsingHeader> createState() => _CollapsingHeaderState();
}

class _CollapsingHeaderState extends ConsumerState<CollapsingHeader> {
  @override
  void initState() {
    super.initState();
    // Cleared on the way in rather than on the way out: a page opens at the
    // top, so it opens uncollapsed -- and `ref` is not safe to touch from
    // dispose, where the widget is already unmounted.
    Future.microtask(() {
      if (!mounted) return;
      ref.read(detailHeaderCollapsedProvider.notifier).set(false);
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final collapsed = notification.metrics.pixels > detailCollapseAfter;
    if (collapsed != ref.read(detailHeaderCollapsedProvider)) {
      ref.read(detailHeaderCollapsedProvider.notifier).set(collapsed);
    }
    // False: this is an observation, not an interception. Any other listener
    // -- the queue's own follow logic, say -- still needs to hear it.
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      );
}

/// What a page's title row becomes once it lives in the caption strip.
///
/// The same shape for every detail page: whatever identifies it, its name,
/// and the actions the page shows beside that name -- kept hover-revealed
/// here too, so the strip does not become a row of buttons competing with
/// the window controls.
class CollapsedTitle extends StatelessWidget {
  const CollapsedTitle({
    super.key,
    required this.leading,
    required this.title,
    this.actions = const [],
  });

  /// A category icon, a cover, a portrait -- whatever the page leads with.
  final Widget leading;

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 4),
        leading,
        const SizedBox(width: 10),
        Flexible(
          child: TitleWithActions(
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            actions: actions,
          ),
        ),
      ],
    );
  }
}

/// Play and shuffle, for the strip once a page's own buttons have scrolled
/// off.
///
/// Icons rather than the labelled buttons the header uses: the strip is 56
/// tall and shared with the window controls, and by the time somebody is this
/// far down a page they know what the page is for. Play stays filled, though
/// -- it is the one control here that should look like the primary action it
/// is everywhere else.
class CollapsedTransport extends ConsumerWidget {
  const CollapsedTransport({
    super.key,
    required this.trackIds,
    required this.source,
    this.sourceRefId,
  });

  final List<int> trackIds;
  final QueueSource source;
  final int? sourceRefId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(playerProvider.notifier);

    Future<void> play({bool shuffled = false}) async {
      await player.playAll(
        trackIds,
        source: source,
        sourceRefId: sourceRefId,
      );
      if (shuffled) await player.shuffleQueue();
    }

    final enabled = trackIds.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          tooltip: 'Play',
          onPressed: enabled ? play : null,
          icon: const Icon(Icons.play_arrow),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Shuffle',
          onPressed: enabled ? () => play(shuffled: true) : null,
          icon: const Icon(Icons.shuffle),
        ),
      ],
    );
  }
}
