import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';

/// The artists and groups list.
///
/// Groups appear here alongside people, marked as groups, because in this app a
/// group *is* an artist - the same table, the same crediting - and hiding them
/// in a separate list would misrepresent the model.
class ArtistsView extends ConsumerWidget {
  const ArtistsView({
    super.key,
    required this.onOpenArtist,
    this.onOpenReview,
  });

  final void Function(int artistId) onOpenArtist;

  /// Opens the credit review queue, when there is anything in it.
  final VoidCallback? onOpenReview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(artistsProvider);
    final sort = ref.watch(artistSortProvider);
    final theme = Theme.of(context);

    final pendingCredits = ref.watch(pendingCreditCountProvider).value ?? 0;

    return Column(
      children: [
        if (pendingCredits > 0 && onOpenReview != null)
          _ReviewBanner(count: pendingCredits, onOpen: onOpenReview!),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(
            children: [
              Text('Artists', style: theme.textTheme.headlineSmall),
              const SizedBox(width: 12),
              Text(
                pluralize(artists.value?.length ?? 0, 'artist'),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              PopupMenuButton<LibrarySort>(
                tooltip: 'Sort',
                initialValue: sort,
                onSelected: (value) =>
                    ref.read(artistSortProvider.notifier).set(value),
                icon: const Icon(Icons.sort),
                itemBuilder: (context) => [
                  for (final option in const [
                    LibrarySort.nameAscending,
                    LibrarySort.nameDescending,
                    LibrarySort.trackCount,
                    LibrarySort.recentlyAdded,
                  ])
                    PopupMenuItem(value: option, child: Text(option.label)),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: artists.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not read the library',
              message: '$error',
            ),
            data: (items) => items.isEmpty
                ? const EmptyState(
                    icon: Icons.person_outline,
                    title: 'No artists yet',
                    message: 'Artists appear once music has been indexed.',
                  )
                : _ArtistGrid(artists: items, onOpen: onOpenArtist),
          ),
        ),
      ],
    );
  }
}

class _ArtistGrid extends StatelessWidget {
  const _ArtistGrid({required this.artists, required this.onOpen});

  final List<ArtistCard> artists;
  final void Function(int artistId) onOpen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const target = 170.0;
        final columns = (constraints.maxWidth / target).floor().clamp(2, 12);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 18,
            mainAxisSpacing: 22,
            childAspectRatio: 1 / 1.28,
          ),
          itemCount: artists.length,
          itemBuilder: (context, index) => _ArtistTile(
            artist: artists[index],
            onTap: () => onOpen(artists[index].id),
          ),
        );
      },
    );
  }
}

class _ArtistTile extends StatefulWidget {
  const _ArtistTile({required this.artist, required this.onTap});

  final ArtistCard artist;
  final VoidCallback onTap;

  @override
  State<_ArtistTile> createState() => _ArtistTileState();
}

class _ArtistTileState extends State<_ArtistTile> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artist = widget.artist;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(
          children: [
            Expanded(
              child: AnimatedScale(
                scale: _hovering ? 1.04 : 1,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                // Circular for people, rounded-square for groups: a shape
                // difference reads faster than a label.
                child: ClipPath(
                  clipper: artist.isGroup ? null : const _CircleClipper(),
                  child: Artwork(
                    storedPath: artist.imagePath,
                    borderRadius: artist.isGroup ? 12 : 999,
                    fallbackSeed: artist.name,
                    fallbackIcon: artist.isGroup
                        ? Icons.groups_outlined
                        : Icons.person_outline,
                    heroTag: 'artist-art-${artist.id}',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              artist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              [
                pluralize(artist.trackCount, 'track'),
                if (artist.isGroup && artist.memberCount > 0)
                  pluralize(artist.memberCount, 'member'),
                if (artist.aliasCount > 0) '${artist.aliasCount} alias',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Clips a widget to a circle inscribed in its box.
class _CircleClipper extends CustomClipper<Path> {
  const _CircleClipper();

  @override
  Path getClip(Size size) => Path()
    ..addOval(Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.shortestSide / 2,
    ));

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}

/// Says how many credits the resolver could not decide, and opens the queue.
///
/// This list is where an unsplit credit does its damage -- a composite name
/// sitting among the real artists -- so this is where the offer to fix it
/// belongs. It disappears entirely once the queue is empty.
class _ReviewBanner extends StatelessWidget {
  const _ReviewBanner({required this.count, required this.onOpen});

  final int count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.secondaryContainer,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
          child: Row(
            children: [
              Icon(Icons.rule, size: 20, color: scheme.onSecondaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${pluralize(count, 'credit')} could not be split '
                  'confidently, so ${count == 1 ? 'it is' : 'they are'} '
                  'waiting on you.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSecondaryContainer),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: onOpen, child: const Text('Review')),
            ],
          ),
        ),
      ),
    );
  }
}
