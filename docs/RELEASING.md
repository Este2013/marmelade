# Releasing marmelade

Everything that happens between "the code is good" and "someone else is running
it". Read the [Setup](#one-time-setup) section once; after that, [Cutting a
release](#cutting-a-release) is the whole job.

## The short version

```bash
# 1. Write down what changed, in lib/core/changelog/changelog.dart.
#    Set the version's `date:` to today.
# 2. Set the same version in pubspec.yaml (keep or bump the +build number).
# 3. Commit both.
git commit -am "chore: release 0.2.0"

# 4. Tag and push. The tag is what triggers everything.
git tag v0.2.0
git push origin main
git push origin v0.2.0
```

CI then builds Windows, publishes a GitHub Release with the zip attached and the
changelog as its notes, and republishes the changelog site. Nothing else is
needed.

## One-time setup

Two things cannot be done from a workflow, and until they are, half of this is
inert:

1. **Enable Pages.** Repository → Settings → Pages → *Build and deployment* →
   Source: **GitHub Actions**. Without this the `Changelog site` workflow fails
   at the deploy step, and the app's changelog fetch gets a 404 (which it
   handles quietly — it falls back to the changelog compiled into the build).
2. **Nothing else.** Releases need no secrets: the workflows use the automatic
   `GITHUB_TOKEN`.

Once Pages is on, the published files are:

| URL | What it is |
| --- | --- |
| `https://este2013.github.io/marmelade/changelog.json` | What the app reads |
| `https://este2013.github.io/marmelade/` | The same thing, for people |

## Where a change gets written down

**`lib/core/changelog/changelog.dart`, and nowhere else.** It is a Dart file
rather than a markdown one on purpose:

- The compiler checks it, so a broken entry fails the build rather than the
  website.
- It is **compiled into the app**, so the running build can answer "what changed
  in the version I am running" instantly, offline, with no fetch. That is the
  question asked most often.
- `tool/changelog_json.dart` imports it and prints JSON, so the website, the
  release notes and the in-app dialog are all generated from the one file and
  cannot disagree. No regex parsing of source code anywhere.

An entry looks like this:

```dart
ReleaseNotes(
  version: '0.2.0',
  date: '2026-09-14',           // null while the version is still open
  headline: 'One sentence, if there is one worth saying.',
  changes: [
    Change.added('What is new, as a sentence, from the reader’s side.'),
    Change.fixed('What stopped being broken.'),
    Change.changed('What behaves differently now.'),
    Change.removed('What is gone.'),
  ],
),
```

Leave `date` null while you accumulate entries between releases; the app shows
such a version as *not released yet*, and the release workflow **refuses to
build a tag whose entry has no date**. That check is the point: it catches
"tagged before writing the notes" at the one moment it is cheap to fix.

## Cutting a release

1. **Changelog.** Add or finish the entry, set `date` to the release date.
2. **Version.** Set `version:` in `pubspec.yaml` to the same version. The build
   number after `+` is yours to use as you like; it never affects ordering.
3. **Check locally** if you want to be sure before pushing a tag:
   ```bash
   dart run tool/changelog_json.dart --check 0.2.0
   flutter analyze && flutter test
   ```
4. **Commit, tag, push** as in the short version. Push the branch *and* the tag;
   pushing only the tag builds a release whose commit is not on `main`.

The tag and `pubspec.yaml` must agree. The workflow fails loudly if they do not,
because a build that reports the wrong version can never see itself as out of
date, and nothing inside the app can detect that.

## Cutting a beta

Exactly the same, with a pre-release suffix on both the version and the tag:

```dart
ReleaseNotes(version: '0.2.0-beta.1', date: '2026-09-10', changes: [...]),
```

```yaml
version: 0.2.0-beta.1+7
```

```bash
git tag v0.2.0-beta.1 && git push origin v0.2.0-beta.1
```

What that changes:

- The GitHub Release is marked **pre-release**, because the version contains a
  `-`.
- The in-app check **ignores it** unless *Settings → About → Include
  pre-releases* is on. Someone on the stable channel is never offered a beta,
  and someone who opted in does not have to watch for them by hand.
- Ordering follows semver: `0.2.0-beta.1` < `0.2.0-beta.2` < `0.2.0`. So a beta
  tester is offered the final release when it lands, and is never offered the
  beta they are already running.

A Windows build with a pre-release version compiles and carries the full string
in the exe's version fields — verified, not assumed.

Betas are ordinary releases in every other way: same zip, same changelog entry,
same site. Nothing needs cleaning up afterwards; when `0.2.0` ships, the beta
entries stay in the history where they belong.

## What each workflow does

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | push to `main`, any PR | analyze, test, debug build |
| `release.yml` | pushed tag `v*` | version/changelog checks, test, release build, zip, publish the Release |
| `pages.yml` | changelog changes, published release | generate `changelog.json` + `index.html`, deploy to Pages |

`release.yml` re-runs the tests rather than trusting `ci.yml`: a tag can point at
a commit CI never saw, and a broken release is worse than a late one.

## How the app uses all this

Three separate questions, answered from three places, because they need
different things:

| Question | Source | Needs network? |
| --- | --- | --- |
| What changed in the version I am running? | the changelog compiled into the build | no |
| Is there a newer version? | GitHub Releases API | yes |
| What would that newer version bring? | `changelog.json` on Pages | yes |

- **On the first launch after an update**, the app shows *What is new in X* once,
  from its own compiled-in changelog. It is marked as seen immediately, so a
  failure downstream cannot make it reappear every launch. A fresh install shows
  nothing — there is no previous version whose changes would be news.
- **The published changelog is fetched once per launch** and cached in the
  settings table. A failed fetch leaves the cache alone, so a launch with no
  network still knows about everything the last successful fetch saw.
- **Settings → About** has *Check for updates*, *Release notes* (the running
  version, with **All versions** for the full history), and the pre-release
  switch. When an update is found, the banner lists what it brings from the
  published changelog, falling back to GitHub's generated notes when the site
  has nothing.
- **Nothing is ever downloaded or installed.** The app opens the release page.
  Fetching an executable and running it needs signature verification to be safe,
  and until there is some, handing you the page is the honest version.

## Trying it without publishing anything

```bash
# The JSON and the page the workflow would publish
dart run tool/changelog_json.dart site/changelog.json
dart run tool/changelog_html.dart site/changelog.json site/index.html

# The markdown a release would carry
dart run tool/changelog_notes.dart 0.1.0

# The gate the release workflow runs
dart run tool/changelog_json.dart --check 0.1.0
```

The in-app dialog can be opened without bumping the version:

```bash
MARMELADE_CHANGELOG=1 build/windows/x64/runner/Debug/marmelade.exe
```

## Not done yet

- **No workflow has ever run.** They are written and their YAML parses, but the
  first real run will be the first tag. Expect to fix something.
- **Nothing is signed.** Windows will warn about an unknown publisher, and the
  app deliberately does not auto-install because of it.
- **No `checkOnStartup` setting yet.** The update check is manual; the key
  exists in `SettingKeys` and nothing reads it.
