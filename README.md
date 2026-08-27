# marmelade

A music player for Windows, for people who be jamming to the tunes. 🍊

Built with Flutter. Local-only: no streaming services, no accounts, no telemetry.
Your files and your database stay on your machine.

## What it is

marmelade indexes folders of music you already own and gives them a library that
actually understands credits. Its main opinion is that **"Name1 x Name2" is two
artists, not one** — so searching `Name1` finds every track they touched, whether
they were credited alone, in a group, behind a separator, or under a Japanese
name you can't type.

- **Formats**: MP3, FLAC, WAV
- **Library**: watched folders, incremental indexing, resilient to files being
  moved, renamed, or retagged behind the app's back
- **Credits model**: artists and groups (with members), per-track roles
  (main / featured / composer / lyricist / remixer / …), and the raw
  "credited as" string preserved alongside the canonical artist
- **Aliases**: any artist, album, or track can carry extra searchable names —
  romanizations, native scripts, abbreviations, common misspellings
- **Tags**: free-form tags grouped into categories. Genres and language from
  file metadata become tag categories automatically
- **Playlists**: hand-built, or *smart* — defined by search terms so they
  re-evaluate as the library changes. Playlists nest
- **Art**: prominent everywhere. A track falls back to its album's art, then its
  artist's, and the now-playing view uses a heavily blurred copy of the art to
  set the colour ambiance
- **Player**: queue, shuffle, per-track and global gain, 10-band parametric EQ,
  playback speed, synced lyrics, a spectrum visualizer, mini-player and
  fullscreen modes
- **Lyrics**: markdown, with a timestamp where a paragraph starts, so the words
  follow the music a verse at a time. Translations sit beside the original and
  can be read together. A file can be linked instead of pasted, and then the
  file stays the source of truth
- **Search**: one field over artists, songs, albums, tags and playlists at
  once. Prefixes match as you type, diacritics fold (`Bjork` finds `Björk`),
  substrings and Japanese work, and a song is found under every artist credited
  on it
- **Stream Deck**: a local control socket, ready for an Elgato Stream Deck
  plugin (the plugin itself is out of scope for now) and handy for debugging

## Status

Early construction. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the
design and [docs/DATABASE.md](docs/DATABASE.md) for the schema.

## Building

Requires the Flutter SDK (beta channel or newer) and the Visual Studio
"Desktop development with C++" workload.

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d windows
```

### Toolchain diagnostics

If audio or the database misbehave, run the standalone probe. It checks sqlite3
(native assets, FTS5, WAL), SoLoud device enumeration, decode coverage across
your fixtures, the FFT taps, and the DSP chain — without any app code involved:

```bash
flutter run -d windows -t tool/diagnostics.dart
```

## Licence

Not yet chosen.
