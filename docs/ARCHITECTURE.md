# Architecture

## Target and constraints

Windows is the primary and only supported target for now. The code avoids
Windows-only APIs where a portable equivalent exists, and isolates the rest
behind interfaces (`lib/platform/`), so adding Linux/macOS later is a matter of
writing new implementations rather than untangling the app.

Out of scope, deliberately: video, streaming services, online metadata
lookup, accounts, telemetry.

## Layers

```
lib/
  app/          MaterialApp, router, theme, window management
  features/     one folder per screen area; UI + its controllers
  domain/       pure Dart: models, artist matching, search grammar
  data/         drift database, DAOs, metadata parsing, filesystem scanning
  services/     audio engine, remote-control socket, updater, art store
  platform/     thin OS-specific wrappers (file identity, media keys, accent)
```

Dependencies point inward: `features` → `domain` ← `data`. `domain` imports
nothing from `data` or `features`, which keeps the artist-matching and search
logic unit-testable without a database or a Flutter binding.

## Key decisions

### State management: Riverpod 3

Providers are the seam between UI and services. `riverpod_generator` is used for
brevity. `riverpod_lint`/`custom_lint` are **not** installed — they currently
pin `analyzer ^6` and cannot resolve against Riverpod 3 / `riverpod_annotation`
4. Revisit when upstream catches up.

### Database: drift over SQLite

SQLite via `package:sqlite3` 3.x, which ships the native library through
Dart **native assets** — no `sqlite3_flutter_libs` (that package is now an
EOL no-op shim) and no manual DLL wrangling. Verified: SQLite 3.53.4 with FTS5
(`unicode61` tokenizer) and WAL journaling, with `sqlite3.dll` placed in the
bundle automatically by the build.

FTS5 matters: it backs the unified search index that makes every artist, album,
tag and alias reachable from one query.

Generated drift code is committed. It keeps CI from needing a codegen step
before it can compile, and makes schema changes visible in review.

### Audio: flutter_soloud

Chosen over `just_audio`/`media_kit` because it is the only option that covers
every audio requirement in one engine, on Windows, natively:

| Requirement | SoLoud provides |
|---|---|
| MP3 / FLAC / WAV decode | miniaudio + bundled FLAC/ogg/vorbis/opus |
| Spectrum visualizer | FFT + waveform taps (`AudioData`) |
| Equalizer | parametric EQ, 1–64 bands, log-spaced 30 Hz–16 kHz |
| Playback speed | `setRelativePlaySpeed` |
| Output device choice | `listPlaybackDevices` / `changeDevice` |
| Gapless / crossfade | `playClocked`, `playScheduled`, `fadeVolume` |
| Waveform seek bar | `readSamplesFromFile` |

It is wrapped behind a `PlaybackEngine` interface (`services/audio/`) so the
engine can be swapped without touching player logic.

Two SoLoud behaviours worth remembering, both found the hard way:

- The visualization tap reads **post-mix output**. Playing at volume 0, or
  during a track's silent intro, yields an all-zero FFT buffer. That is not a
  bug in the tap.
- `bufferSize: 1024` gives visibly better FFT resolution than the 2048 default,
  so that is the app default.

`LoadMode.memory` is the default: instant seeking at the cost of RAM (a decoded
4-minute stereo track is ~80 MB). `LoadMode.disk` is exposed as a setting for
people who would rather trade seek latency for memory.

### Metadata: audio_metadata_reader, raw parsers only

The package is pure Dart, handles ID3v1/ID3v2/Vorbis/RIFF/APE, and can **write**
tags — which the app needs for pushing database edits back into files.

The app calls `readAllMetadata()` and maps the format-specific `ParserTag`
itself. It deliberately does **not** use the convenience `readMetadata()`
wrapper, because that wrapper loses exactly the information the credits model is
built on:

- for MP3 it resolves `artist` as `TPE2 ?? TPE1`, so the *album* artist shadows
  the *track* artist;
- for FLAC it takes `artist.firstOrNull`, discarding multi-value `ARTIST`
  fields — the one case where the file already told us there are several artists.

Mapping the raw frames instead also gives access to `TCOM` (composer), `TEXT`
(lyricist), `TPE4` (remixer), `TOPE` (original artist), `TLAN` (language),
`TXXX` custom frames, `POPM` (rating), embedded `APIC` pictures with their
declared type, and Vorbis ReplayGain fields.

### Theme: Material 3 with the Windows accent colour

`dynamic_color`'s `SystemAccentColor` seeds the scheme from the OS accent.
Album art recolouring uses Flutter's built-in
`ColorScheme.fromImageProvider()` (`palette_generator` is discontinued, and the
built-in is a better fit: it yields a whole coherent M3 scheme, not just a
swatch).

### Searching: tiers, not a score

Two FTS5 indexes back the search box, and both are needed. `search_tokens`
(`unicode61`, diacritics folded) gives ranked word and prefix matching, which is
what makes results appear while you type. `search_trigrams` gives substring
matching, which is the only thing that works mid-word and the only thing that
works at all for a run of Japanese — `unicode61` treats one as a single token,
so a substring of it can never match there.

Ranking is a small integer tier rather than a relevance score. A single opaque
number is impossible to argue with when a result looks wrong, and "the exact
name you typed comes first" is a promise worth being able to check:

| tier | what matched |
| --- | --- |
| 4 | the name is exactly what was typed |
| 3 | the name, or another name it goes by, starts with what was typed |
| 2 | every word matched the name or an alias |
| 1 | matched something else — a credited artist, the album, a tag's category |
| 0 | matched only as a substring |

Within a kind, a tie is broken by how much music the thing accounts for, then by
name. Across kinds — which only decides the single result the view leads with —
an artist named *Amiga* beats a track called *Amiga*.

Two details that are easy to get wrong:

- **User text never reaches `MATCH`.** FTS5 reads `AND`, `OR`, `NOT`, `NEAR`,
  `-`, `*`, `:` and `"` as syntax, so `AC/DC -` would be a syntax error rather
  than a search. Only runs of letters, digits and marks are kept, each quoted as
  its own prefix phrase.
- **A trigram `MATCH` needs three characters.** Two of them is an ordinary
  Japanese word, not half a typed one, so a short query containing a script
  written without spaces falls back to scanning the same haystack with `instr`.

Results are hydrated through the same queries the library grid and lists use, so
a card in search shows exactly what that card shows anywhere else. The ranking
decides *which* things; it never decides what a thing looks like.

The index is maintained per edit, and **Settings → Library → Search index**
rebuilds it. That repair path is not optional: a bug in the bookkeeping leaves
search quietly wrong — finding a name nobody has used for months, or missing one
that is right there — and for a while one did exactly that, because every caller
passed `'artist'` where the index stores `'art'`. `SearchEntity` is now an enum
that carries its own key, so the two cannot disagree again.

### Smart playlists: the query is the playlist

A smart playlist stores no tracks. It is a query plus the library, evaluated when
you look at it, which is why there is no cache to go stale and no "refresh"
button to explain. It stores the text as typed, in a small grammar meant to be
retyped from memory:

```
artist:Nanahira tag:hardcore -tag:remix added:<30d year:>=2015
```

Bare words go through the search index, so a smart playlist inherits the credit
splitting for free: `camellia` collects the collaborations, not just the tracks
where that name happens to be first. Everything with a field becomes SQL against
the catalog, where dates and numbers belong. `tag:` reads the effective tags, so
a tag on the album counts here exactly as it counts everywhere else.

Two deliberate choices:

- **Nothing is rejected.** A query is typed one character at a time, and
  `year:>` is a state on the way to `year:>2015`. An unparseable field value is
  kept as a search word instead of being dropped, and the field says back what
  it understood as you type.
- **`<` reads as "within".** `added:<30d` means added in the last thirty days,
  which is what someone typing it means, even though the comparison on the
  stored timestamp runs the other way. The inversion is written out rather than
  being clever, because it is exactly the kind of thing a refactor reverses.

A *hybrid* playlist is the query's results plus rows added by hand, minus
explicit exclusions. The exclusion is the reason hybrid exists: one otherwise
perfect query with one song you never want to hear.

## Testing strategy

- `domain/` is covered by plain `dart test` — separator tokenizing and artist
  resolution are pure functions over strings, and that is where the interesting
  bugs live.
- The database layer is tested against an in-memory SQLite instance.
- `tool/diagnostics.dart` is a runnable integration probe for the native stack.

Test fixtures live in the music library under `_marmelade_fixtures/` and are
generated with ffmpeg. They cover MP3/FLAC/WAV, 16/24-bit, 44.1/48/96 kHz,
untagged files, duplicate content at two paths, and a deliberately hostile set
of artist strings: `Camellia x Nanahira`, `AC/DC`, `Simon & Garfunkel`,
`Earth, Wind & Fire`, `PinocchioP, Hatsune Miku feat. Kasane Teto`,
`初音ミク、重音テト`, `REOL ✕ Giga`, `t+pazolite | Nanahira`.

The last group is the point: a correct implementation must split the first,
sixth, seventh, eighth and tenth while leaving `AC/DC`,
`Simon & Garfunkel` and `Earth, Wind & Fire` intact.

## Updates

GitHub Actions builds a Windows release on tag. Binaries are published as
**GitHub Release** assets; the `gh-pages` branch hosts a small `latest.json`
manifest plus a landing page. The app polls the manifest, compares against its
own version, and offers the download.

Release binaries do not live on `gh-pages` itself: every build committed to a
branch stays in git history forever and would bloat the clone without limit.
