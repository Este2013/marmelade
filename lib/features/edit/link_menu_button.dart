import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/repositories/edit_repository.dart';
import 'link_visuals.dart';

/// Distinguishes the "Edit links" row from an actual [LinkRow] without
/// needing a sum type: [PopupMenuButton] hands back whatever value the
/// tapped item carried, by identity, so any object nothing else could equal
/// works as the marker.
const _editLinks = Object();

/// A link icon that opens every external link for one thing, favicon and all.
///
/// Nothing is rendered when there is nothing to show *and* nothing to add --
/// a permanently-present but empty or disabled button is worse than no
/// button, and flipping one between disabled and enabled is its own
/// accessibility-bridge fault on Windows (see docs/ARCHITECTURE.md). But the
/// button has to survive having zero links whenever editing is possible, or
/// there would be no way to reach "Edit links" to add the first one.
class LinkMenuButton extends StatelessWidget {
  const LinkMenuButton({super.key, required this.links, this.onEditLinks});

  final List<LinkRow> links;

  /// Opens the editor for these links. Null where editing is not offered
  /// here at all, matching whatever already gates the rest of this page's
  /// editing (an artist page with no `onEditArtist`, say).
  final VoidCallback? onEditLinks;

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty && onEditLinks == null) return const SizedBox.shrink();

    return PopupMenuButton<Object>(
      tooltip: 'Links',
      icon: const Icon(Icons.link),
      onSelected: (value) {
        if (identical(value, _editLinks)) {
          onEditLinks?.call();
          return;
        }
        final link = value as LinkRow;
        launchUrl(Uri.parse(link.url), mode: LaunchMode.externalApplication);
      },
      itemBuilder: (context) => [
        for (final link in links)
          PopupMenuItem(
            value: link,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinkKindIcon(kind: link.kind),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    link.label ?? linkKindLabel(link.kind),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (onEditLinks != null) ...[
          if (links.isNotEmpty) const PopupMenuDivider(),
          const PopupMenuItem(
            value: _editLinks,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_outlined, size: 18),
                SizedBox(width: 12),
                Text('Edit links'),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
