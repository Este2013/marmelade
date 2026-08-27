# Artist matching

The complaint this is built to answer: a track tagged
`artist = "Name1 x Name2"` is filed under a single artist called
"Name1 x Name2", so searching `Name1` doesn't find it.

Fixing that naively — split on every separator — breaks a different set of
music, permanently and invisibly. `AC/DC` becomes two artists. So does
`Simon & Garfunkel`. `Earth, Wind & Fire` becomes three. `t+pazolite` becomes
two. `Maxence Cyrin` becomes "Ma" and "ence Cyrin".

So the interesting problem is not splitting. It is knowing **when not to**.

## Three layers

Splitting is separated into three pieces that can each be reasoned about
alone. The first two are pure functions over strings, which is why they are
covered by 49 unit tests with no database in sight.

### 1. Normalisation — `domain/text/normalize.dart`

Everything is matched on a folded key, never on the raw string.
`normalizeKey` lower-cases, strips accents, folds full-width Latin to ASCII,
folds hiragana onto katakana, and turns punctuation into word breaks.

```
Björk          -> bjork
ＲＥＯＬ         -> reol
ぴのきおぴー      -> ピノキオピー
AC/DC          -> ac dc
```

Two consequences worth noticing. Full-width folding matters because Japanese
tag editors emit it constantly, so `ＲＥＯＬ` and `REOL` must not become two
artists. And hiragana/katakana folding means someone typing a name the "wrong"
way still finds it.

`compactKey` additionally drops spaces, so `AC/DC`, `AC DC` and `ACDC` all
collapse to `acdc`. It is only consulted after an exact key match fails.

### 2. Tokenisation — `domain/credits/credit_tokenizer.dart`

Purely lexical. Splits a string on separators and knows nothing about which
artists exist.

Separators are **data, not code** (`separator_tokens` table), because no fixed
list survives contact with a real collection. Each carries two independent
flags, and conflating them is the classic mistake:

- **`requiresSpaces`** — a lexical guard. The token only counts when
  surrounded by whitespace. This is what keeps `x` out of "Ma**x**ence", `+`
  out of "t**+**pazolite" and `/` out of "AC**/**DC". Note that this alone
  already solves `AC/DC` and `t+pazolite`, with no cleverness required.
- **`isAmbiguous`** — a semantic warning: real names are known to contain this
  token. `,` needs no spaces to be a separator, yet "Earth, Wind & Fire" is one
  band. Conversely `|` is essentially never part of a name.

Roles are assigned while scanning: everything after `feat.` is a guest credit,
and the role is sticky, so `A feat. B & C` gives one lead and two guests.
Bracketed forms are unwrapped, so `A (feat. B)` tokenises the same as
`A feat. B`.

### 3. Resolution — `domain/credits/credit_resolver.dart`

Decides whether a lexical split should actually be applied, using knowledge of
the library. Rules, in precedence order:

1. **An exact match on an existing artist or alias wins over everything.**
   Once `AC/DC` exists as an artist, its name can never be split again. This is
   the strongest guarantee in the system, and it is why letting users fix
   things once is enough.
2. **No separator → one artist.** Nothing to decide.
3. **An unambiguous separator settles it.** No artist is called
   `初音ミク、重音テト` or `A feat. B`. Split outright, high confidence.
   This also applies when ambiguous and unambiguous separators are mixed:
   `PinocchioP, Hatsune Miku feat. Kasane Teto` contains `feat.`, so the whole
   string demonstrably is not one name, and the commas can be trusted too.
4. **Ambiguous separators alone require corroboration** (below).
5. **Otherwise, do nothing and ask.** The credit is parked in
   `pending_credits` with the declined split attached, so accepting it is one
   click. The track still plays; only its credits wait.

Rule 5 is the important one. Guessing wrong writes bad data that the user may
not notice for months. Asking is cheap.

## Corroboration: the corpus is the evidence

For ambiguous separators, the resolver looks at the **whole library** rather
than the file in front of it. This is the part that makes it feel smart.

Indexing runs in two phases. Phase one reads every credit string and counts, for
each candidate name, how often it appears:

- **standalone** - as an entire credit string;
- **confirmed** - as a segment of a credit split on an *unambiguous* separator;
- **ambiguous** - as a segment of an ambiguous split (weak; it may just be a
  word inside a band name).

Phase two resolves with those counts in hand. A name is *attested* if it is
standalone or confirmed.

The confirmed bucket matters more than it looks, and leaving it out is what
makes a naive implementation fail on the exact case this feature exists for.
Running against a real collection:

> `Camellia x Nanahira` was kept whole. Neither "Camellia" nor "Nanahira" ever
> headlines a track in that library - each is only ever seen inside
> `Camellia VS Kobaryo` and `t+pazolite | Nanahira`. Both of those used
> trustworthy separators, so both had already *proven* the names are real. That
> proof was being thrown away.

Counting confirmed segments as attestation fixes it, and the two shapes that
are identical to a regex now separate cleanly:

| Credit string | Parts attested? | Verdict |
|---|---|---|
| `Camellia x Nanahira` | yes - both proven by trustworthy splits elsewhere | **split** |
| `Earth, Wind & Fire` | no - "Earth", "Wind", "Fire" appear nowhere else | **keep whole** |
| `LukHash x Shirobon` | one - LukHash has albums of his own | **split** (see below) |

Neither needed an artist row to exist beforehand, and neither needed a
hard-coded list of band names. The collection answers the question about
itself.

### Weighing the parts against the whole

A real band name recurs. A one-off collaboration credit does not. So when one
part is well attested and the full string has been seen at most once, it is a
collaboration:

> `Grand Thaw & Rigel Theatre`, seen once, where `Rigel Theatre` has 195
> tracks -> **split**.

It reverses when nothing vouches for any part: a full string that keeps turning
up on its own, whose pieces appear nowhere else, is a name, and the resolver
keeps it whole.

### One attested part is enough

Requiring *every* part to be attested was the rule for a while, and on a real
library it failed the exact case this feature exists for:

> `LukHash x Shirobon` was kept whole and parked for review -- "nothing
> corroborates a split here (1 of 2 parts attested)" -- while LukHash had two
> albums of his own in the same library. His name was on screen with no page
> behind it.

So one attested part now carries the split. A band coincidentally named
`LukHash x Shirobon` while LukHash exists alone in the same collection is
far-fetched, and the alternative is the failure the app was built to remove.

Note that this deliberately overrides the recurring-whole rule above. It has to:
evidence is counted once per *track*, so a twelve-track collaboration album
gives its credit twelve sightings and makes it look like a recurring name.
Guarding on that would have refused precisely the album-length collaborations a
real library is full of.

What bounds the risk is rule 1. Correct a bad split once -- by merging the
artists, or by adding the band as an artist with the never-split flag -- and the
exact-match rule keeps it corrected forever, whatever its parts are attested as.
The behaviour is a setting (**split on any attested part**), so the conservative
rule is one toggle away.

On the 5,216-file reference library, turning this on took credits parked for
review from **479 to 9** and composite artist names from ~46 to ~14, with the
nine survivors being strings where neither part is a known artist -- which is
where a human should be asked.

### Two further signals

- **Comma lists vs. band names.** `Alice, Bob, Carol` splits - three
  comma-separated parts reads as a list. `Alice, Bob & Carol` does not: a comma
  list terminated by a conjunction is the classic English band-name shape.
- **Majority attestation.** If two of three parts are known, that is enough to
  split and create the third.

## Script pairs are one artist, not two

A slash between a Latin name and a native-script one is how people write a name
beside its romanisation, not a collaboration:

```
PinocchioP / native-script spelling   ->   one artist, the other as an alias
```

Splitting that would produce two half-populated artist pages for one person;
keeping it whole would produce an artist whose name is two names. Neither is
right, so this gets its own outcome, and the alias falls out for free - which is
precisely what makes a native-script artist reachable from a Latin keyboard.

The detection is deliberately narrow: **only the slash**, and only when exactly
one side contains CJK. A genuine cross-script collaboration is written with a
multiplication sign, `feat.` or a comma, and all of those stay splits. If one
spelling is already a known artist, that one becomes canonical. The behaviour
can be turned off in settings.

## Learning

Every confirmed decision is stored in `credit_split_rules`, keyed by the
normalised credit string. The same string is never re-guessed. A user who
resolves "Name1 x Name2" once has resolved it for every track that carries it,
now and in future scans.

`artists.never_split` is the manual override for a name the resolver keeps
getting wrong.

## Why credits are rows, not strings

`track_credits` holds one row per artist per track, with a `role` and a
`credited_as` string. That last column is what lets the app have it both ways:
the track displays "ピノキオピー" exactly as its file spelled it, while linking
to the canonical artist that also answers to "PinocchioP".

Because credits are rows, "every mention of an artist is one click from their
page" is not a feature that needs building — it falls out of the schema.

## Reviewing what is left

Whatever the rules do, some credits come down to knowledge the library does not
contain. Those are parked in `pending_credits` rather than guessed at, and the
Artists list offers them for review -- badged on the rail and bannered above the
list, because that list is where an unsplit credit does its damage.

The queue is grouped by the credit *string*, not by track. The same field
usually appears on every track of a release, and answering the same question
twenty times is not review, it is data entry. Each card shows the resolver's own
reasoning, how many tracks it affects, and three choices:

| Choice | What it does |
|---|---|
| **Split** | Rewrites the credit on every affected track. The suggested parts are editable first, since a parked credit is often parked because it needs a small fix. |
| **Keep as one artist** | Accepts it as a name and sets `never_split` + `is_verified`, so a rescan stops asking. Without the flag the review would not stick. |
| **Skip** | Marks the rows decided without changing anything. It will return if a rescan meets the same impasse, which is honest: nothing was settled. |

Two details that matter more than they look:

* **The role comes off the row being replaced, not the suggestion.** The stored
  suggestion records tokenizer roles (`main`, `featured`), not the field's own
  role, so rewriting a composer field from the suggestion alone would turn two
  composers into two main artists.
* **The composite artist row is deleted after a split**, if it is childless and
  unverified. A leftover "Koiflower,Bangler" with no tracks is exactly the mess
  the review exists to clear up.

Split credits are written with `source = user`, so a later rescan leaves them
alone.

## Settings that affect this

- **Aggressive splitting** (default off) — act on ambiguous separators without
  corroboration. Populates a library faster, mangles more band names. When on,
  results are still reported at low confidence rather than pretending to be
  certain.
- **Separator editor** — add, disable, or reclassify any token, including the
  built-ins, without losing your own additions.
- **Split on any attested part** (default on) — one known artist inside the
  string is enough to treat the field as a list. Off restores the stricter rule,
  which asks for review instead of guessing.
- **Whole-name evidence threshold** (default 2) — how many standalone
  sightings of a full string are enough to conclude it is a real name.
- **Strong attestation threshold** (default 2) — how well attested one part
  must be before it outweighs a rarely-seen whole.
- **Detect script pairs** (default on) — treat a Latin/native-script slash pair
  as one artist with an alias.

## Testing

`test/domain/credit_resolver_test.dart`. The interesting half of the suite is
the strings that must **not** split:

```
AC/DC              Simon & Garfunkel      Earth, Wind & Fire
t+pazolite         Maxence Cyrin          Andrew Bird
```

against those that must:

```
Camellia x Nanahira    REOL ✕ Giga        初音ミク、重音テト
t+pazolite | Nanahira  Camellia VS Kobaryo
PinocchioP, Hatsune Miku feat. Kasane Teto
```

and the pair that must become one artist plus an alias, rather than either:

```
PinocchioP / native-script spelling
```

Fixtures carrying exactly these tags live in the music library under
`_marmelade_fixtures/`, generated by ffmpeg, so the same cases can be run
end-to-end through a real scan.

`tool/index_dry_run.dart` runs the whole pipeline over a folder and reports
every decision with its reason, without touching a database:

```bash
dart run tool/index_dry_run.dart "<your music folder>"
```

Every rule above beyond the first draft came from reading that output against a
real collection. It is the fastest way to find a tagging convention the
separator list does not cover yet.
