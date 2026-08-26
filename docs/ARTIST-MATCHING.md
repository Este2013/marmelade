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
covered by 40 unit tests with no database in sight.

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

Indexing runs in two phases. Phase one reads every credit string and counts how
often each candidate name appears **standalone** versus **as part of a
composite**. Phase two resolves, with those counts available.

That single fact separates the two cases that look identical by shape:

| Credit string | Parts seen alone elsewhere? | Verdict |
|---|---|---|
| `Camellia x Nanahira` | yes — both headline their own tracks | **split** |
| `Earth, Wind & Fire` | no — "Earth", "Wind", "Fire" never appear alone | **keep whole** |

Neither needed an artist row to exist beforehand, and neither needed a
hard-coded list of band names. The collection answers the question about
itself.

Two further signals:

- **Comma lists vs. band names.** `Alice, Bob, Carol` splits — three
  comma-separated parts reads as a list. `Alice, Bob & Carol` does not: comma
  list terminated by a conjunction is the classic English band-name shape.
- **Majority attestation.** If two of three parts are known artists, that is
  enough to split and create the third.

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

## Settings that affect this

- **Aggressive splitting** (default off) — act on ambiguous separators without
  corroboration. Populates a library faster, mangles more band names. When on,
  results are still reported at low confidence rather than pretending to be
  certain.
- **Separator editor** — add, disable, or reclassify any token, including the
  built-ins, without losing your own additions.
- **Whole-name evidence threshold** (default 2) — how many standalone
  sightings of a full string are enough to conclude it is a real name.

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

Fixtures carrying exactly these tags live in the music library under
`_marmelade_fixtures/`, generated by ffmpeg, so the same cases can be run
end-to-end through a real scan.
