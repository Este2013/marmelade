import 'package:flutter/material.dart';

import '../../data/db/enums.dart';

/// A name worth showing, rather than the enum's own `camelCase`.
String linkKindLabel(LinkKind kind) => switch (kind) {
      LinkKind.website => 'Website',
      LinkKind.youtube => 'YouTube',
      LinkKind.twitter => 'X (Twitter)',
      LinkKind.bluesky => 'Bluesky',
      LinkKind.mastodon => 'Mastodon',
      LinkKind.bandcamp => 'Bandcamp',
      LinkKind.booth => 'Booth.pm',
      LinkKind.soundcloud => 'SoundCloud',
      LinkKind.spotify => 'Spotify',
      LinkKind.appleMusic => 'Apple Music',
      LinkKind.niconico => 'Niconico',
      LinkKind.pixiv => 'Pixiv',
      LinkKind.musicbrainz => 'MusicBrainz',
      LinkKind.vgmdb => 'VGMdb',
      LinkKind.wikipedia => 'Wikipedia',
      LinkKind.other => 'Other',
    };

/// The bundled favicon for a kind, or null where none is stored.
///
/// [LinkKind.website] and [LinkKind.other] have no single site to draw one
/// from -- those fall back to a generic icon instead.
String? _asset(LinkKind kind) => switch (kind) {
      LinkKind.website || LinkKind.other => null,
      _ => 'assets/link_icons/${kind.name}.png',
    };

/// The icon to draw when there is no favicon for a kind.
///
/// A plain website gets [Icons.open_in_browser] rather than the generic chain
/// link: it is the one kind that *is* just "somebody's own page", and the
/// browser glyph says what clicking it does. The chain stays for
/// [LinkKind.other], which is the shrug case, and for a favicon that failed
/// to load, where the kind is known but its mark is not available.
IconData fallbackLinkIcon(LinkKind kind) => switch (kind) {
      LinkKind.website => Icons.open_in_browser,
      _ => Icons.link,
    };

/// The colour to paint behind a kind's favicon, where its own mark does not
/// fill the square.
///
/// Most of these logos are a full-bleed tile -- Bandcamp, Spotify, Booth --
/// and read as badges beside each other with nothing added. Four do not:
/// their marks sit on transparency, so among filled squares they look like
/// gaps, and the dark ones all but vanish against a dark theme (Niconico's
/// television is `#252525`, VGMdb's glyph `#D40000`). Painting each site's
/// own background behind it makes them squares like the rest, which is what
/// the sites themselves do in an app icon.
///
/// The exact colours matter, and these are sampled from the assets: YouTube's
/// mark is `#FF0033`, not pure red, and painting `#FF0000` behind it leaves a
/// two-tone square with a visible pill in the middle of it.
Color? _badge(LinkKind kind) => switch (kind) {
      LinkKind.youtube => const Color(0xFFFF0033),
      LinkKind.niconico || LinkKind.bluesky || LinkKind.vgmdb => Colors.white,
      _ => null,
    };

/// A small icon for a link kind: its favicon where one is stored, a generic
/// icon otherwise.
class LinkKindIcon extends StatelessWidget {
  const LinkKindIcon({super.key, required this.kind, this.size = 22});

  final LinkKind kind;

  /// Side of the square. Big enough by default to be legible at a glance in
  /// a row of tag chips, which is where most of these are read.
  final double size;

  @override
  Widget build(BuildContext context) {
    final asset = _asset(kind);
    if (asset == null) {
      return Icon(
        fallbackLinkIcon(kind),
        size: size,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
    }
    return ClipRRect(
      // Proportional, so the corners stay in step whatever size is asked
      // for rather than looking sharp at 22 and round at 14.
      borderRadius: BorderRadius.circular(size * 0.22),
      child: ColoredBox(
        color: _badge(kind) ?? Colors.transparent,
        child: Image.asset(
          asset,
          width: size,
          height: size,
          // A favicon fetched once and bundled can still be missing for a
          // kind added after the asset pull -- fall back rather than show
          // the "broken image" glyph.
          errorBuilder: (context, error, stack) => Icon(
            fallbackLinkIcon(kind),
            size: size,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Guesses a kind from a URL someone has actually pasted in.
///
/// A best-effort match against the domains each kind's site actually uses,
/// not a promise: an unrecognised domain reads as a plain website rather than
/// as an error, and either guess is one click away from being corrected by
/// hand. No request is made -- this is a string match, nothing more.
LinkKind inferLinkKind(String url) {
  final uri = Uri.tryParse(url.trim());
  final host = uri?.host.toLowerCase() ?? '';
  if (host.isEmpty) return LinkKind.other;

  bool has(String domain) => host == domain || host.endsWith('.$domain');

  return switch (host) {
    _ when has('youtube.com') || has('youtu.be') => LinkKind.youtube,
    _ when has('twitter.com') || has('x.com') => LinkKind.twitter,
    _ when has('bsky.app') => LinkKind.bluesky,
    // Federated, so there is no single domain -- the well-known flagship
    // instances are as far as a guess can reasonably reach.
    _ when has('mastodon.social') ||
        has('mastodon.online') ||
        has('mastodon.world') =>
      LinkKind.mastodon,
    _ when has('bandcamp.com') => LinkKind.bandcamp,
    _ when host.endsWith('.booth.pm') => LinkKind.booth,
    _ when has('soundcloud.com') => LinkKind.soundcloud,
    _ when has('spotify.com') => LinkKind.spotify,
    _ when has('music.apple.com') => LinkKind.appleMusic,
    _ when has('nicovideo.jp') => LinkKind.niconico,
    _ when has('pixiv.net') => LinkKind.pixiv,
    _ when has('musicbrainz.org') => LinkKind.musicbrainz,
    _ when has('vgmdb.net') => LinkKind.vgmdb,
    _ when has('wikipedia.org') => LinkKind.wikipedia,
    _ => LinkKind.website,
  };
}

/// The greyed example shown in the URL field for a kind, so the shape of what
/// is wanted is visible before anything is typed.
String? linkKindHint(LinkKind kind) => switch (kind) {
      LinkKind.youtube => 'https://www.youtube.com/@artistname',
      LinkKind.twitter => 'https://x.com/artistname',
      LinkKind.bluesky => 'https://bsky.app/profile/artistname.bsky.social',
      LinkKind.mastodon => 'https://mastodon.social/@artistname',
      LinkKind.bandcamp => 'https://artistname.bandcamp.com',
      LinkKind.booth => 'https://artistname.booth.pm',
      LinkKind.soundcloud => 'https://soundcloud.com/artistname',
      LinkKind.wikipedia => 'https://en.wikipedia.org/wiki/Artist_Name',
      _ => null,
    };

/// A real URL to offer for [artistName], built from the pattern most sites of
/// this kind actually use.
///
/// Only offered where that pattern is a guessable slug -- Spotify, Apple
/// Music, Niconico and Pixiv address artists by an opaque id, not a name, so
/// nothing here would be more than a wrong guess dressed as an answer.
/// Everything this returns is still a guess to check, not a fetched fact: no
/// request is made, and the field stays editable before it is saved.
String? linkKindSuggestion(LinkKind kind, String artistName) {
  final slug = artistName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '');
  if (slug.isEmpty) return null;

  return switch (kind) {
    LinkKind.youtube => 'https://www.youtube.com/@$slug',
    LinkKind.twitter => 'https://x.com/$slug',
    LinkKind.bluesky => 'https://bsky.app/profile/$slug.bsky.social',
    LinkKind.mastodon => 'https://mastodon.social/@$slug',
    LinkKind.bandcamp => 'https://$slug.bandcamp.com',
    LinkKind.booth => 'https://$slug.booth.pm',
    LinkKind.soundcloud => 'https://soundcloud.com/$slug',
    LinkKind.wikipedia =>
      'https://en.wikipedia.org/wiki/'
          '${artistName.trim().split(RegExp(r'\s+')).join('_')}',
    _ => null,
  };
}
