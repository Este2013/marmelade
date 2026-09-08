


## Now playing view

## Artist/albums details

- should not be able to push a duplicate of the item details when one was already there. Instead, the push should remove the old duplicate details view and put the new one on top. This means for exemple, I should never have stacked view: Artist List > Artist X > Artist Y > Artist X, where going back brings me to artist X again.

## Playlist list
## Other general features:

## Database durability (shelved 2026-09-04, agreed to do later)

The live library was genuinely corrupt this session -- one page claimed by two
b-trees, `lyrics` handing back `tracks` rows -- caused by the app refusing to
close, being killed, and leaving the write-ahead log unfolded. Repaired with a
row-by-row rebuild into a fresh file (zero data loss, proven table by table);
old file kept as `marmelade.db.corrupt-backup-20260904-193717` under
`%APPDATA%\dev.este2013\marmelade\`. The close hang itself is fixed (2f3702d).

What is *not* done, in the order worth doing it:

1. **Rotating backups.** `VACUUM INTO` a dated file, keep ~7 generations,
   integrity-check each before rotating the oldest out so a good copy is never
   discarded. ~10 MB each. Turns corruption from unknown loss into "lose at
   most a day". The single highest-value item.
2. **Refuse to run on a damaged file.** Startup already detects damage, then
   REINDEXes and carries on regardless -- which is how 55 problems became 73
   over two launches. Open read-only instead, say so plainly, and offer the
   row-by-row repair from Settings.
3. **Single-instance guard.** No lock today, so two instances can write the
   same file; the never-closing window made zombies routine. Second launch
   should focus the first window.
4. **Keep the WAL short.** `wal_autocheckpoint` is 1000 pages (4 MB) but the
   log reached 8.8 MB, so checkpointing was being blocked -- most likely by
   long-lived drift stream read transactions. An explicit
   `wal_checkpoint(TRUNCATE)` on idle or after a scan shrinks the window.
5. **Integrity-check before export/import**, so a damaged library gives a
   sentence rather than a raw SqliteException in a snackbar.

Ruled out already, do not re-investigate: AppData\Roaming is a real local
folder on a fixed disk, not redirected, OneDrive does not cover it; the app
opens exactly one database connection per process. `synchronous = FULL` is
deliberately not on the list -- WAL + NORMAL already survives an app crash, so
it would only buy protection against OS crash or power loss, at a real cost to
scan throughput.

## Pull request (shelved 2026-09-04)

A PR was requested and then shelved; the work went straight to `main` instead.
Nothing outstanding unless a reviewable PR is still wanted for these commits.

## From the 2026-09-06 16:30 session log (found while chasing the queue bug)

Two things worth their own look; neither is the queue bug, which is fixed
(826fadd).

1. **The database close still hangs.** That session ended with
   `ERROR [shutdown] closing the database did not finish in 4000ms, moving on`
   -- the bounded shutdown doing its job, but the underlying hang is real and
   happening on ordinary use. Before the timeout existed this is exactly what
   left the window open forever and the WAL unfolded. Worth finding out what
   drift is waiting on: likely a query or transaction still in flight against
   the background isolate at close time. The checkpoint runs first, so the file
   is safe either way.

2. **Memory grows a lot over a session.** Same log: 324 MB at startup,
   **1.98 GB** at shutdown after ~5.5 hours. The image cache is capped at
   220 MB, so that is something else -- candidates are decoded artwork outside
   the cache, per-track SoLoud sources not being disposed, or accumulated
   stream subscriptions. Measurable with a long run plus periodic
   `AppLog.residentBytes()`, which is already logged at startup and shutdown
   only.
