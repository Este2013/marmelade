import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/repositories/edit_repository.dart' show LinkRow;
import 'link_visuals.dart';

/// One of an artist's external links, as a small button that opens it.
///
/// These used to live behind a single link icon that opened a menu. Sitting
/// them in the tag line instead -- one icon per link, each its own site's
/// favicon -- means a glance says *where* an artist can be found rather than
/// that they can be found somewhere, and reaching Bandcamp is one click
/// rather than two. It reads as a row of badges beside the tags, which is
/// what a set of links to somebody's pages actually is.
///
/// Sized to sit among the tag chips rather than as a full 40-pixel icon
/// button: the row is chip-height, and a stack of standard buttons would set
/// the line's height from the one thing on it that is not a chip.
///
/// [size] is a compact [Chip]'s measured height, so a link and a tag on the
/// same line are the same height. `link_icon_button_test.dart` asserts that
/// against a real chip rather than trusting this number, because a change to
/// the chip's density or label style would move it.
class LinkIconButton extends StatelessWidget {
  const LinkIconButton({super.key, required this.link, this.size = 30});

  final LinkRow link;

  /// Side of the square tap target.
  final double size;

  /// The favicon inside it, all but filling the box.
  ///
  /// Nearly the whole square on purpose: the favicon *is* the mark here,
  /// where a chip's own outline is what gives a tag its height. Insetting it
  /// the way an icon button normally would left the badges visibly shorter
  /// than the chips they sit beside.
  double get _glyph => size - 2;

  @override
  Widget build(BuildContext context) {
    final label = link.label ?? linkKindLabel(link.kind);
    final host = Uri.tryParse(link.url)?.host;

    return Tooltip(
      // The host as well as the label, because "Website" or "Other" says
      // nothing about where the click goes.
      message: [label, if (host != null && host.isNotEmpty) host].join(' · '),
      child: SizedBox(
        width: size,
        height: size,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: _glyph,
          // A malformed URL is a row somebody typed by hand, not a crash.
          onPressed: () {
            final uri = Uri.tryParse(link.url);
            if (uri == null) return;
            launchUrl(uri, mode: LaunchMode.externalApplication);
          },
          icon: LinkKindIcon(kind: link.kind, size: _glyph),
        ),
      ),
    );
  }
}
