# Indexing

How files on disk become a library. The requirement driving the design: the
index must survive the filesystem being reorganised behind the app's back —
files moved, renamed, retagged, or on a drive that is not plugged in today —
without losing ratings, play counts, tags or anything the user edited by hand.

## The pipeline

```
scan ─→ reconcile ─→ read tags ─→ gather evidence ─→ resolve ─→ write ─→ artwork ─→ search
```

Two passes over the credit strings, not one. Everything is gathered before
anything is resolved, because deciding whether `Camellia x Nanahira` is one
artist or two needs to know what the rest of the collection looks like. See
[ARTIST-MATCHING.md](ARTIST-MATCHING.md).

### 1. Scan — `data/fs/library_scanner.dart`

Walks a folder with an explicit stack rather than `Directory.list(recursive:)`,
so whole subtrees can be pruned before they are entered. Skips
`$RECYCLE.BIN`, `.git`, `__MACOSX`, and — from a real library — the `_files`
directories that browsers create when saving a web page.

Paths are stored **relative to the folder root with forward slashes**, so
re-rooting a whole library (a drive letter change, a collection moved) is one
update to the folder row rather than a rewrite of every file.

What it skipped is counted and reported, not silently dropped: "found 12 m4a
files, not indexed" is a better answer than nothing.

### 2. Reconcile — `data/fs/file_reconciler.dart`

Compares the scan against the existing rows and produces operations:
`KeepFile`, `UpdateFile`, `MoveFile`, `AddFile`, `MarkMissing`.

Unchanged files — same path, size and timestamp — take a fast path with no
hashing at all. A rescan of an untouched library does no I/O beyond the walk.

**Move detection** is the interesting part. A file that vanishes from one path
while unfamiliar content appears at another is, overwhelmingly, the same file:
someone tidied their folders. Naive indexers see a delete and an insert, and
throw away everything the user had accumulated about the track. Here the row is
repointed instead.

Two constraints fall out of that:

- Identity must be **recorded before the file disappears**, because a file that
  is already gone cannot be re-hashed. So every indexed file stores its hash.
- A vanished file is **marked missing, never deleted**. An unplugged drive
  costs nothing, and the row comes back when the drive does.

### 3. File identity — `data/fs/audio_payload.dart`, `file_identity.dart`

Hashes are taken over the **audio payload**, not the file. Editing a title
rewrites the tag block and shifts every byte after it, so a whole-file hash
changes; a payload hash does not. That is what lets a file that was retagged
*and* moved in the same breath still be recognised as one move.

Locating the payload means parsing container headers — a few kilobytes,
regardless of file size:

| Format | Payload boundaries |
|---|---|
| MP3 | after the ID3v2 header (sync-safe size), before trailing ID3v1 / APEv2 / Lyrics3v2, and an MPEG frame sync must be found |
| FLAC | after the metadata block chain's last-block flag |
| WAV | the `data` chunk, clamped when its declared size overruns the file |

The frame-sync requirement is not decoration: without it, 2 KB of noise was
reported as a valid exact payload, and callers would have trusted a hash that
guaranteed nothing. An unrecognised container degrades to a whole-file range
and *says so* (`AudioPayloadRange.exact == false`), so move detection still
works while tag-invariance is not silently promised.

Two hashes, both xxh3:

- **`quickKey`** — payload length plus 128 KB from each end. Computed for every
  file; cheap enough to be unconditional.
- **`contentKey`** — the whole payload. Computed only to *confirm* a suspected
  move, since reading every byte of a fifty-thousand-file library is not a
  thing to do on principle. A setting turns it on for people who want moves
  confirmed rather than inferred.

### 4. Read tags — `data/metadata/`

Raw frames, mapped deliberately. The convenience wrapper in
`audio_metadata_reader` is avoided because it destroys exactly what the credits
model needs — see the note in `tag_reader.dart`.

For FLAC the Vorbis comment block is parsed directly
(`data/fs/vorbis_comments.dart`), because the package maps both `ARTIST` and
`ALBUMARTIST` into one list. That makes the album artist unreadable *and* makes
"one artist plus an album artist" indistinguishable from "genuinely two
artists". Repeated `ARTIST` fields are the most reliable multi-artist signal a
file can carry — the file stating the answer outright — so it is worth reading
correctly rather than inferring around.

`RawCredit.isPreSplit` marks values from a genuinely multi-valued field
(repeated Vorbis `ARTIST`, NUL-separated ID3v2.4, `TXXX:ARTISTS`). Those bypass
the resolver entirely: heuristics can only make a well-tagged file worse.

### 5. Write — `data/indexer/catalog_writer.dart`

Every write is an upsert keyed on a normalised name, so a rescan is idempotent
and never creates a second "Camellia" because one file spelled it differently.

**User data is never overwritten.** Rows flagged `isVerified`, and credits or
tags whose source is `user`, survive a rescan untouched. This is what makes it
safe to invite people to correct the library by hand.

Writes are batched (200 files per transaction): one transaction for a whole
library would hold a write lock for minutes, one per file would fsync thousands
of times.

Two files holding the same song share one track row, so an MP3 and a FLAC of
the same album track do not split the play count between formats. Identity is
by content hash first, then by album plus track number plus title — requiring
all three keeps unrelated songs that share a title from being merged.

### 6. Artwork — `data/fs/art_sidecar.dart`, `services/art/art_store.dart`

Artwork is a property of a *folder* far more often than of a file: one
`cover.jpg` serves a whole album. So the artwork pass works a directory at a
time and probes each folder once rather than once per track. Embedded pictures
are only extracted when the folder offered nothing, because decoding a
multi-megabyte `APIC` frame per track is the expensive path.

The store is **content-addressed** — `artwork/<sha256[0:2]>/<sha256>.<ext>` —
so one cover embedded in fifty tracks occupies one file, and re-importing a
library writes nothing new. Files are written to a temporary name and renamed,
so a crash cannot leave a corrupt file sitting at a path whose name is a promise
about its contents.

Naming conventions were taken from a real library rather than invented:
`cover` / `folder` / `front` / `album` for covers, `artist.jpg` **and**
`<Name>_artist.jpg` for portraits, `.ico` files ignored (that library keeps one
beside every portrait, for folder icons).

A portrait found in a `[Collection] <Artist>` folder is applied **only to the
artist that folder names**. Applying it to every artist in the tree hands the
collection owner's photo to each guest and collaborator inside it — which is
exactly what an early version did.

### 7. Search — `data/indexer/search_indexer.dart`

Rebuilt from the catalog with bulk `INSERT ... SELECT`, so a full rebuild is a
handful of queries. Maintained from Dart rather than SQL triggers: triggers
across eight source tables would be hard to reason about, and a search index
with no repair path is a liability.

Tracks are indexed by their own title, their aliases, **every artist credited on
them**, and their album. That is what makes "an artist name is always one click
from its page" fall out of the schema instead of needing UI work.

## Reporting

Nothing fails silently. `scan_runs` records every run with its counters;
`scan_issues` records unreadable files, unsupported formats and ambiguous
credits; `pending_credits` holds credit strings the resolver declined to guess
at, each with the interpretation it declined so accepting it is one click.

Counters report what was actually written, not what was attempted. An earlier
version asked the resolver whether an artist was new, which inflated the count
from 31 to 771 on a real library — the resolver's vocabulary is a snapshot from
before the write pass, so it keeps calling artists new that were created moments
earlier in the same run. The writer reports its own inserts instead.

## Measured

Against a real 380-file library (370 mp3, 2 FLAC, 2 WAV, plus assorted junk):

```
files seen 380   added 380   unreadable 0
tracks 379   artists 31   albums 44   images 41   credits 411
needs review 2
2.2 s  (175 files/sec)
```

A second run over the same unchanged library does no work at all.

## Tools

```bash
# Resolve credits and report every decision, without writing anything.
dart run tool/index_dry_run.dart "<folder>" [--verbose]

# Run the real indexer and report what landed in the database.
dart run tool/index_library.dart "<folder>" [--db <path>] [--keep]
```

Both are plain Dart, no Flutter binding needed — which is why `path_provider`
lives in `app/storage_paths.dart` and not in the data layer.

Every fix in this document beyond the first draft came from reading those tools'
output against a real collection.
