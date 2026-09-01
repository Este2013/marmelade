import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/repositories/edit_repository.dart';
import 'link_visuals.dart';

/// A link icon that opens every external link for one thing, favicon and all.
///
/// Nothing is rendered when there is nothing to show: a permanently-present
/// but empty or disabled button is worse than no button, and flipping one
/// between disabled and enabled is its own accessibility-bridge fault on
/// Windows (see docs/ARCHITECTURE.md).
class LinkMenuButton extends StatelessWidget {
  const LinkMenuButton({super.key, required this.links});

  final List<LinkRow> links;

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<LinkRow>(
      tooltip: 'Links',
      icon: const Icon(Icons.link),
      onSelected: (link) => launchUrl(
        Uri.parse(link.url),
        mode: LaunchMode.externalApplication,
      ),
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
      ],
    );
  }
}
