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

### Transfer between computers: merge, never restore

The same music on two machines, with the tagging done on whichever one it was
downloaded to. A bundle of portable JSON carries everything hand-entered, keyed
by what things *are* — a normalised name, an image's sha256, a track's payload
fingerprint — so it means the same thing on a machine that has never seen this
library. Files are matched on `quick_key`, which covers the audio bytes only and
therefore survives retagging.

The decision that shapes it: **both machines get used**, and nothing in the
schema reliably says which edit came first — favourite toggles and play counters
are written with raw SQL that never touches `updated_at`, and ten tables have no
timestamp at all. So there is no last-writer-wins. Collections are unioned,
scalars only fill blanks, flags are additive, counters take the larger side, and
disagreements are counted rather than resolved silently. The cost is that
deletions do not propagate; of the two ways to be wrong, resurrecting a tag is
the one you can see.

Sharing is a folder, not a service: each machine writes only
`<folder>/machines/<its own id>/` and reads the others, so no two computers ever
write the same file and a cloud client can sync it whenever it likes. Put the
folder in Drive or Dropbox and that is the integration. Audio is opt-in.

See [TRANSFER.md](TRANSFER.md).

### Lyrics: markdown with timestamps

One format covering the three states lyrics actually arrive in -- a block of
text pasted from anywhere, an LRC file where every line is timed, and the one
this app is for: markdown where a timestamp on its own line starts a new
paragraph, so a song scrolls a verse at a time rather than a word at a time.

Markdown is deliberately a subset: headings, emphasis, `>` notes, paragraphs.
Lyrics are short structured text with the occasional aside, and every construct
beyond that list is one more thing that renders differently from what someone
typed. Nothing throws -- files come from strangers and the editor feeds it text
that is half-typed by definition, so a malformed timestamp becomes text.

Translations are separate rows keyed by `(track, language)`, aligned to the
original by timestamp when both are timed and by position when they are not. A
verse the translation skipped stays untranslated rather than pairing with
whatever timestamp is nearest.

A document can be pasted or linked. When it is linked the file is the source of
truth and the stored text is a cache, re-read when the file is newer; saving in
the editor takes ownership back and unlinks. A document cannot be both, because
one of the two would silently win on the next refresh.

**The highlight animates opacity, not text style.** Animating between two font
sizes re-lays out the paragraph on every frame of the transition and moves every
semantics rectangle with it -- measured at three times the accessibility-bridge
errors (17 against a baseline of 5), on the same bridge where a zero-area node
once crashed the app outright. Opacity animates a render object and leaves
layout alone.

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

## Debugging on Windows

### Isolates stuck "paused on entry"

A debug session that opens with both `main` and `Drift isolate worker for
…marmelade.db` showing *paused on entry*, needing a manual resume each, is not
the app. Flutter starts the main isolate paused so the debugger can install
breakpoints, and the extension resumes it; the drift worker
(`NativeDatabase.createInBackground`, [`lib/data/db/database.dart`]) is a second
isolate that gets the same treatment.

My first theory here — more than one VM service client holding the resume —
was checked and **ruled out**: no second client was attached (checked the Call
Stack panel, DevTools, and stray `dart`/`flutter_tester` processes) and the
pause still happened. That explanation was wrong; this note previously stated
it as fact, which it should not have.

The working theory now: the drift worker isolate spawns roughly 600ms after
`main()` starts (`AppServices.start`, [`lib/app/providers.dart`]), which is
squarely in the window where VS Code's debug adapter may still be attaching to
the *first* isolate. A second isolate starting mid-attach is a known shape of
Dart-Code/DAP bug where the adapter's isolate bookkeeping gets confused for
both isolates at once, matching what is seen here — not a slow resume, but one
that never arrives without a manual click, on *both* isolates, though only the
second one is new. `AppServices.start` now waits 1.2s before opening the
database, **only in debug builds**, to put more space between the two isolates
starting. **This is unverified** — there is no way to drive an actual VS Code
DAP session from here to confirm it. If the pause still happens with this in
place, the isolate-spawn-timing theory is wrong and the cause is upstream in
the SDK tooling (worth checking on a Flutter beta channel this fresh: `flutter
--version` reads 3.45.0-0.1.pre / Dart 3.13.0-103.1.beta at the time of
writing), not something app code can reach.

`.vscode/launch.json` holds an explicit configuration so F5 is not guessing one.

### Accessibility bridge errors

`accessibility_bridge.cc … Failed to update ui::AXTree` on stderr means the
Windows bridge rejected a semantics update. It is noisy rather than fatal on its
own, but a sustained flood eventually corrupts the bridge's copy of the tree and
kills the process on the next full rebuild.

**Four app-code causes have been found and fixed**, all the same shape —
something that **adds, removes or re-creates a semantics node every frame**:

- an interactive widget parked at zero size (`SizedBox(width: 0)`),
- a `Transform` (e.g. `AnimatedScale`) wrapped around a subtree that contains an
  interactive node, which moves that node's geometry every frame,
- a button flipped between `onPressed: null` and a callback on hover, which
  rewrites the node rather than updating it,
- (see below) not app-fixable, but confirmed to correlate with the same fault
  shape rather than something else.

**A methodology correction, since it changes what the numbers below mean:**
the first pass at measuring this drove input with `SendKeys(' ')` aimed at
screen coordinates, with no real mouse click — which turned out to not
reliably focus or open anything at all. A real click needs an actual
`mouse_event` button-down/up, not just moving the cursor there. Redone with
real clicks: typing 25 real keystrokes into a plain `TextField` now measures
**~1 error total**, not "one per two keystrokes" as previously written here —
that earlier number was very likely stray hover/startup noise picked up while
the fake "click" did nothing. Typing itself looks clean. Take any AXTree
number in this file from before this correction with that in mind.

**Confirmed, with real clicks, and not fixable here:**

- **scrolling** — roughly one error per scroll tick, present with all hover
  handling removed entirely, so it is the `Scrollable`'s own semantics update;
- **app startup** — exactly **2** errors on a totally cold launch with zero
  interaction, same two node ids every time (106, 97). `MARMELADE_NO_SEMANTICS`
  removes one of the two, not both — the remaining one is likely above the
  app's own widget tree (root/window-level semantics setup), out of reach from
  application code. This is what "switching to any view, even empty search"
  actually was: the view that happens to be on screen when this fires reads as
  the cause, but a controlled test (open search once, switch to albums,
  re-open search) shows the count fixed at startup and never climbing on any
  later switch, including a second visit to the same section.
- **opening any overlay menu** (a `PopupMenuButton`, the existing right-click
  context menu) can produce a distinct, repeating shape: "Nodes left pending by
  the update: 134 135 ... 142", the same nine ids, over and over for as long as
  the menu stays open. Confirmed on the pre-existing track right-click menu,
  untouched this session, at the same ids as a brand-new `PopupMenuButton` --
  so this is the dropdown-open fault's cousin, not a new one.
- **opening a `DropdownButtonFormField` menu** — real, but noisy and **does
  not scale with the number of items**: a single open of a 4-item dropdown
  (Groups) measured 3, 8 and 3 errors across separate runs; a single open of
  the 15-item Link Kind dropdown measured 2 and 3. If anything the shorter
  list was noisier. "One error per item in the list" was a reasonable guess
  from watching it happen, but the measured counts don't support it — whatever
  is happening looks like the same kind of noise as the scroll and startup
  cases, not a per-item cost.

Given a scroll tick, a stock dropdown nobody wrote custom code for, and app
startup itself all throw at a broadly similar, noisy, non-scaling rate, this
still reads as a fault in the engine's Windows accessibility bridge on this SDK
build rather than a pattern in this app's widgets. There is no known app-side
fix, and after two rounds of measurement this has reached diminishing returns
for the time it costs to keep chasing — `MARMELADE_NO_SEMANTICS=1` strips
semantics entirely (`lib/main.dart`) for a clean log while debugging something
else, which is the practical answer for now. If it becomes worth another look,
the next step is upstream: the Flutter engine issue tracker for this SDK
version, or the same repro on the stable channel instead of beta.

To measure, run the built exe with stderr redirected, drive **real** mouse
input (`mouse_event` down *and* up, not just moving the cursor) or keyboard
input over the window from PowerShell, and `grep -ci axtree`. Confirm the
click actually landed (a focused field shows its focus outline in a
screenshot) before trusting a count from it. Neither can be produced by the
screenshot hook, and none of this reproduces in a widget test.
