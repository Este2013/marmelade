/// Reads a web address out of something a person typed.
///
/// Nobody types the scheme. Links get pasted as `artist.bandcamp.com` or
/// `www.vgmdb.net/artist/123`, and to `Uri` those are a *path* -- no scheme,
/// no host -- so opening one did nothing, its tooltip lost the site name, the
/// kind guessed from its domain came out as "Other", and asking it for a
/// picture answered "that link is not a web address". One missing prefix,
/// four different symptoms.
///
/// So assume `https` when no scheme is given, which is what a browser's
/// address bar does and what the person meant. Returns null only when there
/// is no address to be had.
Uri? webUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  // Protocol-relative, as copied out of some page's markup.
  if (text.startsWith('//')) {
    return _looksLikeHost(text.substring(2)) ? Uri.tryParse('https:$text') : null;
  }

  final parsed = Uri.tryParse(text);
  if (parsed != null && parsed.hasScheme && !parsed.scheme.contains('.')) {
    // A dotted "scheme" is a host that got mistaken for one: `Uri` reads
    // `bandcamp.com:8080/x` as the scheme `bandcamp.com`, since dots are
    // legal in a scheme, and that one belongs to the branch below.
    //
    // Any word before a colon parses as a scheme, though -- a note reading
    // `TODO: find this` has the scheme `todo` -- so a scheme is believed only
    // when it brought an address with it: `scheme://host`, or `mailto`, which
    // legitimately has no host. Everything it does believe is left exactly as
    // it was, web or not; whether it can be opened is the caller's call.
    if (parsed.hasAuthority || parsed.scheme == 'mailto') return parsed;
  }

  return _looksLikeHost(text) ? Uri.tryParse('https://$text') : null;
}

/// Whether what comes before the first `/`, `?` or `#` could be a hostname.
///
/// Free text must not quietly become an address. `Uri` accepts `not a url`
/// as the host `not%20a%20url` without complaint, so assuming a scheme has to
/// be spelled out as assuming one *when this looks like a domain* -- else
/// every stray note in a link field would read as a website nobody can open.
/// A dot is the test: every site worth linking has one, a bare word does not.
bool _looksLikeHost(String text) {
  final authority = text.split(RegExp('[/?#]')).first;
  if (authority.contains(RegExp(r'\s'))) return false;
  final host = authority.split(':').first;
  return host.length > 2 &&
      host.contains('.') &&
      !host.startsWith('.') &&
      !host.endsWith('.');
}
