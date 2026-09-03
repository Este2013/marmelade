# Transfer

Moving a library between computers. The requirement driving the design: the
same music sits on a work machine and a home machine, files get copied
between them, and none of the work — split credits, aliases, tags, ratings,
playlists — travels with the audio. Doing it twice is the thing to eliminate.

Both machines get used, so this is a merge, not a restore. That single fact
decides almost everything below.

## The bundle

`data/transfer/transfer_bundle.dart` — a folder containing JSON, and
optionally files:

```
<bundle>/library.json
<bundle>/artwork/<sha256>.jpg     when artwork is included (default)
<bundle>/audio/<relative path>    when audio is included (opt-in, off)
```

Three rules the format obeys:

- **Nothing machine-local.** No row ids, no absolute paths. An artist is a
  normalised name plus a disambiguation, an album is a name plus its artist
  and year, a tag is a category slug plus a name, an image is its sha256, a
  track is the fingerprints of its files.
- **References are bundle-local.** Inside one bundle, entities point at each
  other by the exporting machine's row id — convenient, self-consistent,
  meaningless elsewhere, and remapped on import. That is why the exporter
  needs no translation pass of its own.
- **Additive by nature.** A bundle says what exists, never what was deleted.

JSON rather than a copy of the database, because a copy would carry the other
machine's paths and ids, would overwrite rather than merge, and could not be
read by a person wondering what went wrong.

Left out on purpose: `media_files` rows, library folders, the play queue, scan
history, and the pending-credit review queue (which rebuilds itself on the
next scan).

## Matching a track to the same track elsewhere

`quick_key` is the join key. It is the app's payload fingerprint (see
[INDEXING.md](INDEXING.md)): xxh3 over the audio bytes only, skipping tag
blocks, so **retagging a file does not change it** and a copied file keeps it
exactly. `content_key` would be better but is null in practice — the indexer
only computes it on demand.

The ladder, most conclusive first:

| # | Signal | Means |
|---|---|---|
| 1 | `content_key` | identical audio, conclusive |
| 2 | `quick_key` + size | the same file |
| 3 | `quick_key` | the same audio, different tags |
| 4 | relative path + size | the same file in the same tree |
| 5 | name + size + length | almost certainly the same file |
| 6 | name + size | probably the same file |
| 7 | title + album + track no. | the same *song*, opt-in only |

Rung 7 is behind "also match by title and album" because it is a guess — it
exists for a re-download or a FLAC here and an MP3 there.

A track in the bundle that matches nothing here is **reported, not created**.
A track row with no file behind it shows up in every list and plays nothing;
the honest answer is "copy the audio across and import again", which is what
the opt-in audio folder is for.

## Why the merge is not last-writer-wins

There is no trustworthy per-field timestamp to sort by:

- `tracks.is_favorite` and `albums.is_favorite` are toggled with raw SQL that
  never touches `updated_at` (`widgets/track_list.dart`,
  `features/library/album_detail_view.dart`).
- `play_count` / `skip_count` likewise (`services/audio/player_controller.dart`).
- Ten tables have no timestamp column at all: `artist_links`,
  `artist_memberships`, `album_aliases`, `track_aliases`, `track_credits`,
  `album_credits`, `tag_aliases`, `playlist_track_order`, `separator_tokens`,
  and `images` (which has only `created_at`).

So a timestamp-keyed merge would silently eat whichever side it liked less.
Instead:

| Kind of data | Rule |
|---|---|
| Collections — tags, credits, aliases, links, memberships, playlist entries | **Union.** Added if absent, never removed. |
| Scalars — rating, sort name, description, year, disc/track no. | **Fill blanks.** Where both differ, this machine wins and the disagreement is counted. |
| Flags — `is_favorite`, `is_verified`, `never_split` | **Additive.** A yes from either machine is kept: `false` is what a row looks like when nobody was asked. |
| Counters — play and skip counts | **Larger side.** Adding them would double-count everything from before the two libraries diverged. |
| `credited_as` on an existing credit | Filled in if missing. It is the whole point of the credit model. |
| A playlist's query | Adopted only by a playlist that has none. Changing what a playlist means without being asked is worse than not syncing it. |
| A hand-dragged track order | All or nothing. Merging two arrangements produces one neither machine asked for. |

`TransferConflictPolicy.preferTheirs` flips the scalar rules for one run.
Nothing ever deletes, in either policy.

The cost, stated plainly: **deletions do not propagate.** Removing a tag on
one machine and then syncing brings it back from the other. That is the
deliberate trade — a bundle cannot tell "deleted over there" from "added over
here since the export", and of the two ways to be wrong, resurrecting a tag is
the one you can see and fix.

Every counter in `TransferReport` is "rows actually changed", so importing the
same bundle twice reports zeros the second time. That idempotence is what the
shared folder depends on.

## Preview

`LibraryImporter.import(preview: true)` runs the **same code** inside a
transaction that is then rolled back. Not a second implementation of the
estimate — that is the only way a preview can be trusted to match what
pressing the button does. Artwork file copies are skipped in preview, since
the filesystem is not part of the transaction (an orphan in the
content-addressed store is harmless and the pruner collects it).

## Sharing through a folder

`data/transfer/library_sync.dart`. No server, no account:

```
<folder>/machines/<machineId>/library.json
```

**A machine only ever writes its own subfolder and only ever reads the
others.** Two computers never write the same file, so a cloud client syncing
whenever it likes cannot produce a conflict — no lock, nothing to resolve, and
two machines exporting at the same moment is a non-event. Convergence comes
from the import being additive and idempotent, not from any ordering
guarantee.

This is the answer to "can it use Google Drive": put the folder inside Drive,
Dropbox or OneDrive and their client moves it. Strictly better than an
integration here — it works with whatever service the user already pays for,
keeps the library out of an API this app would need credentials for, and fails
visibly in a file manager.

`machineId` is random and generated once per installation, stored in
`settings`. Not derived from the hostname (which changes) or from hardware
(which a music player has no business fingerprinting).

A bundle whose `exportedAt` is not newer than the last one read from that
machine is skipped. Re-importing would be harmless, but reading and merging a
whole library to change nothing is not free.

## Where things live

| Piece | File |
|---|---|
| Format and JSON codec | `data/transfer/transfer_bundle.dart` |
| Progress, options, reports | `data/transfer/transfer_report.dart` |
| Library → bundle | `data/transfer/library_exporter.dart` |
| Bundle → library, and the merge | `data/transfer/library_importer.dart` |
| The shared folder | `data/transfer/library_sync.dart` |
| Settings UI | `features/settings/transfer_section.dart` |
| Job controller and providers | `app/providers.dart` |
| Tests | `test/data/library_transfer_test.dart`, `test/ui/transfer_section_test.dart` |

## Known gaps

- **Deletions.** See above. A "forget what this machine no longer has" mode
  would need per-row tombstones, which the schema has nowhere to put yet.
- **`content_key` is never computed**, so rung 1 of the ladder is dead in
  practice. A backfill pass over the export set would make matching airtight
  for re-encoded files; rungs 2–6 cover copied ones already.
- **Three write paths skip `updated_at`** (both favourite toggles, the play
  counters). Fixing them would not change the merge rules above, but it would
  make a future timestamp-aware mode possible.
- **Play history** (`play_history`) is not carried, only the counters derived
  from it.
