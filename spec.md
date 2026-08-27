# Vaultline Ingest — Architecture Spec

**Status: IMPLEMENTED, RELEASE CANDIDATE BUILT. Active development.**

---

## 1. The idea, and why it's the best one in this project so far

One downloadable app that is **both** the free ingest tool *and* the Relay client
that paying Vaultline customers install.

- **Unpaired** (no Vaultline): a genuinely good free offloader. Copy from card to
  destinations, verify with checksums, rename to your convention, write a manifest.
  Configured by the user in Settings.
- **Paired** (Vaultline customer): the same binary, pointed at a Media Nexus. It becomes
  the client side of Relay — reports drives, pushes ingest events, receives its naming
  and workflow config from the server.

Why this matters more than it sounds:

| | |
|---|---|
| **One codebase, one signing pipeline, one update path** | Instead of a free tool plus a separately maintained client agent |
| **It kills the install command** | No more "run this script to install the Relay client." Clients download an app, paste a URL, done. That removes a real friction point in the six-stage build process — the install stage |
| **Free users are already running the client** | Upgrading isn't a migration, it's entering a server address. The gap between free tool and paid product becomes one text field |
| **The free tool stops being a throwaway** | It's production software the paying clients depend on, which means it stays maintained by necessity rather than goodwill |

This also directly serves the Labs strategy: it's a free tool carved from a real module
(Ingest's naming convention builder, checksum verification, card import) that
demonstrates the paid product by *being part of it*.

---

## 2. The fork: this cannot be the same app as Drive Inspector

**Decision: two separate apps. Do not merge them.**

Drive Inspector's strongest claim is that it is sandboxed with **no network entitlement
at all** — provable by anyone with `codesign`. That claim is unique, it can't be
honestly copied, and it's the reason a stranger trusts a free binary pointed at their
archive.

Ingest needs the opposite posture:

| | Inspector | Ingest |
|---|---|---|
| Files | read-only | **read-write** |
| Network | none, enforced | **required when paired** |
| Risk if wrong | a wrong number | **lost footage** |

Entitlements are static — you cannot have network "only when paired." Merging the two
would spend Inspector's claim to save a menu item. Keep them separate; they share code
via a small internal package, not a bundle.

### Proving the network claim without entitlements

Ingest can't prove restraint the way Inspector does, so it proves it behaviourally:

- **A Network panel in Settings that logs every single request the app makes** —
  method, host, path, byte count, timestamp. Not a sample. All of them.
- Unpaired, that list stays empty forever, and the user can see that it does.
- No analytics, no telemetry, no update check, no crash reporting. The only host it
  ever contacts is the Media Nexus address the user typed in.

Verifiable behaviour is weaker than a verifiable entitlement, but it's honest, and it's
more than any competitor offers.

---

## 3. The rule that outranks every feature

**An ingest tool that loses footage ends the company.**

Everything below is subordinate to this. Non-negotiable behaviours:

1. **Copy, never move.** Moving is not a v1 feature. The source card is untouched.
2. **Never delete anything.** Not the source, not a "duplicate," not on cleanup. The app
   has no delete path at all.
3. **Never overwrite silently.** A destination collision stops and asks, every time.
4. **Verify before reporting success.** A file is "done" only after it has been read
   back from the destination and its checksum matched. Not after the write returns.
5. **Fail loud, resume clean.** A failed or interrupted ingest reports exactly which
   files are verified and which aren't, and can be re-run without redoing verified work.
6. **The manifest is written last**, and only covers verified files.

Anything that conflicts with these loses, including speed.

---

## 3a. The app is two halves

Revised 2026-08-07. It isn't only an offloader.

**Drives** — the standing view, useful on a day nobody is ingesting anything.
Every drive this Mac has seen, when it was last plugged in, **what changed since
the time before**, and whether named collections appear on one drive, matching drives,
or discrepant drives. Scanning is manual by default. A user or managed Media Nexus
configuration can opt into scan-on-mount and restrict collection tracking with a
folder-name regular expression. This preserves a non-surprising standalone default
while allowing a Relay workstation to follow team rules whenever the app is open.

**Ingest** — the offload pipeline in §4.

### What "what changed" costs

A per-file index of a 500k-file drive is tens of megabytes of JSON per drive per scan;
the registry would outgrow the media it describes. So the snapshot is a **folder-level
fingerprint** — `(name, size, mtime)` hashed per file, folded into one digest per
folder. That catches everything practical (added, removed, resized, replaced) at a
fraction of the size, and the diff is a set comparison rather than a walk.

Drives are keyed on **volume UUID**, not path. A registry keyed on `/Volumes/Untitled`
would merge three different cards into one entry.

### The scope limit, said out loud in the UI

Copies of this app **cannot see each other's drives.** There is no peer discovery and
no shared index — what it knows is what has been plugged into this Mac. That's an
honest limit, and it's also the cleanest possible statement of what Media Nexus adds:
pairing turns "the drives I've plugged in" into "the drives we own".

The Drives view says this in plain language rather than letting someone assume
otherwise and discover it during a crisis.

Within one Mac, the app compares tracked folders across every retained drive snapshot.
This is a fast inventory comparison over relative paths and sizes, not a content
checksum. It may say that inventories match; only the Ingest read-back checksum is
allowed to say that a copy is verified.

### Overlap with Drive Inspector — resolved by sequencing, not by argument

Both apps scan drives. The distinction that matters isn't what they report, it's the
**relationship with the user**:

| | Drive Inspector | Vaultline Ingest |
|---|---|---|
| Shape | **one-shot.** Answer a question, close it | **resident.** Left open, used over time |
| Commitment | download, run, done | adopt, configure, keep |
| Network | none, provably | client, when paired |

That's a marketing distinction more than a product one, and it argues *for* keeping
Inspector: the ask is far smaller. A stranger will download something that answers one
question much more readily than something they have to adopt. Inspector is the cheap
front door; Ingest is the commitment. Different rungs of the same ladder.

The cost against is real too — two release pipelines, two support surfaces, two sets of
download-page claims to keep honest, for a company with one person and no clients yet.

**Decision: don't choose now, sequence it.** Inspector is already built, so shipping it
costs nothing further.

1. Ship **Inspector alone** first. It also proves signing, notarization and the download
   flow on a read-only app whose worst failure is a wrong number.
2. Ship **Ingest** a few weeks later.
3. If Inspector pulls people in, keep both. If it doesn't, retire it and fold its report
   into Ingest — `ReportBuilder` is self-contained, so that's a port, not a rewrite.

**Never launch them the same week.** Simultaneous release is the only scenario where the
overlap genuinely confuses anyone.

---

## 4. Ingest pipeline

```
source card/drive
   │
   ├─ scan & plan ──── what's there, how big, where it's going, collisions
   │
   ├─ copy ─────────── read source once, fan out to N destinations
   │                   hash the source stream while reading (free)
   │
   ├─ verify ───────── read each destination back, hash, compare to source
   │
   ├─ rename ───────── apply the naming convention (on destinations only)
   │
   └─ manifest ─────── ASC MHL sidecar + human-readable report
```

**Read the source once.** Hash it during the read, write to every destination from that
same buffer. A two-destination offload should cost one source read, not three.

### Checksums

Default **xxHash64**. It is what the industry actually uses (Hedge, Silverstack,
ASC MHL) and it runs at gigabytes per second, so verification isn't the bottleneck —
MD5 would make the checksum slower than the disk. MD5 and SHA-1 available for
compatibility with a client who requires them.

Implemented locally (`XXHash64.swift`) — there's no system xxHash on macOS.

### Manifest

Write **ASC MHL**, not a bespoke format. It is the interchange standard for offload
manifests, other tools read it, and it makes the free app trustworthy in a way a
proprietary `.json` never would. A plain-language HTML/PDF handoff summary alongside it.

---

## 5. The setup wizard — learn the convention instead of asking for it

Nobody can describe their naming convention accurately. They can point at a drive.

**Flow:** point the wizard at existing work → it tokenizes real file and folder names →
infers candidate patterns → shows each with live examples from *their* files → they pick
and edit → writes `naming.json`.

What the analyzer looks for:

- **Date tokens** — `YYYYMMDD`, `YY-MM-DD`, `DDMMYY`, and where they sit
- **Camera/reel tokens** — `A001`, `C0043`, `CAM_B`, single-letter reel prefixes
- **Sequence tokens** — zero-padded counters, and their width
- **Project/client codes** — recurring uppercase segments across many folders
- **Separators** — the actual delimiter in use, and how consistent it is
- **Folder depth grammar** — e.g. `Project / Shoot Date / Camera / files`

It should also report **how consistent the existing convention is** — "84% of folders
match this pattern, 16% don't" — with the exceptions listed. That number is often the
most useful thing the wizard produces, because it's the first time anyone has measured
it.

This is the Ingest platform's naming-convention-builder module, carved out and given
away. Exactly the Labs pattern.

### Structure creation

The same convention drives **creating** folder trees for a new job, not just matching
existing ones — because that's where naming actually goes wrong, before the card is
even inserted.

The default template separates **Shoot** from **Edit** at the top level. Most teams
have no separation at all: camera media, exports, graphics, music and project files end
up in one pile, and two years later nobody can tell which of six similarly-named folders
holds the originals. Shoot is write-once and never touched again; Edit is where
everything churns. That one line is most of the value.

`StructureBuilder.swift` — three built-in templates (Shoot + Edit, Shoot only,
Minimal), all editable. Creating a folder is the one write this app does that isn't a
copy, so the same rules apply: nothing deleted, nothing replaced, an existing folder
reported rather than touched.

**Not doing: generating Premiere/Resolve project files.** Project formats are
undocumented, version-fragile, and a corrupt project on a shoot day would cost more
trust than the feature could ever earn.

### The ingest form

Optional, and **the fields are configured by the user**. Every team wishes a different
set of things had been written down at the card — production, shoot day, DP, location,
whether it's cleared to archive — so we ship suggestions, not a fixed schema.

Answers are written next to the media as a **plain text sidecar**, along with a factual
record the app writes itself: files verified, checksum algorithm, destinations, clashes,
per-file hashes. Plain text because it survives every migration, opens anywhere, is
readable in fifty years, and gets indexed by Spotlight and Vaultline alike. A database
row is gone the day the app is uninstalled.

When paired, non-empty answers are also included in the ingest event as metadata with
stable field IDs, labels, kinds, and values. That lets Archive and other Media Nexus
modules use the context without hardcoding a client's form schema. The local sidecar is
still written and remains the durable standalone record.

Fields marked *sticky* carry to the next card; the rest clear. Retyping the production
name eleven times is how forms stop getting filled in.

---

## 6. Configuration — one shape, two sources

The config is the same document whether the user typed it or the server sent it.

```
~/Library/Application Support/Vaultline Ingest/config.json
```

```jsonc
{
  "version": 1,
  "source": "local",              // or "nexus"
  "naming": { … },                // naming.json contents
  "destinations": [ … ],          // labelled paths, primary/backup roles
  "checksum": "xxhash64",
  "workflow": { "verify": true, "manifest": "asc-mhl", "onCollision": "ask" },
  "nexus": { "url": "", "deviceName": "", "pairedAt": null }
}
```

**When paired, the server's config wins** and the local file becomes a cache, clearly
marked read-only in the UI so nobody wonders why their edit reverted. Unpaired, the user
owns it.

This is deliberately the same config-package idea as the client build process — one
schema, filled locally or centrally. A client's Vaultline install pushes the same
`naming.json` to every workstation instead of each editor configuring their own.

---

## 7. Media Nexus integration (the Relay client)

Only active when paired. Everything is push-from-client; the server never reaches in.

| Direction | What moves |
|---|---|
| **client → nexus** | Ingest events (source, destinations, file list, checksums, verified status, operator, timestamps) · volume registry (capacity and identifiers) · tracked-folder scan summaries and inventory fingerprints |
| **nexus → client** | Config (naming, destinations, workflow) · drive registry names so a card reads as "NS-024" not "Untitled" |

**Never sent:** media. Only metadata and checksums. The app has no upload path for
footage and never will — that boundary is the entire reason a client trusts a local-first
system.

Pairing: user pastes a Nexus URL and a short pairing code; the client registers itself
and stores a device token. Unpair wipes the token and reverts to local config.

Every request appears in the Network panel (§2).

---

## 8. v1 scope — deliberately small

**In:**

- Card/drive offload to 1–2 destinations, single source read
- xxHash64 verification with read-back
- ASC MHL manifest + human-readable handoff summary
- Naming convention wizard (analyze → propose → confirm)
- Folder structure creation from the convention
- Settings: destinations, checksum, collision policy, Nexus pairing
- Network panel

**Out of v1** — each is a whole product on its own:

transcoding · proxy generation · LTO/tape · cloud upload · review/approval ·
metadata tagging · scheduled/watch-folder ingest · Windows

**Never:** delete, move, or modify source media.

---

## 9. Naming

Working name **Vaultline Ingest** — *not* "Vaultline Labs Ingest."

Drive Inspector carries the Labs prefix because it is a Labs experiment. This app is
production client software that paying customers will depend on for their footage. The
Labs prefix would undersell it and confuse the support expectation. Worth confirming
against `vaultline-brand` before locking.

---

## 10. Sequencing — the honest recommendation

**Ship Drive Inspector first.** It is written, audited, and days from a release; this app
is weeks. Shipping Inspector proves the whole distribution chain — signing, notarization,
DMG, download page, the update flow — on a small read-only app whose worst failure mode
is a wrong number.

Then build Ingest on a pipeline that is already known to work, and whose worst failure
mode is somebody's footage.

Building the second, larger, file-*writing* app before the first has ever shipped is
exactly the pattern the Labs charter exists to prevent.

---

## 11. Open questions

- Whether the Nexus protocol is REST + device token, or something else. Needs deciding
  alongside the secure-remote-access question already open in the strategy
- Whether unpaired users get a "connect to Vaultline" prompt at all, or whether it stays
  quietly in Settings (leaning quiet — nagware would poison the free tool)
- Whether the naming wizard's consistency score becomes its own shareable report, the way
  Inspector's does
- Whether v1 supports simultaneous multi-card ingest or one at a time (leaning one)
- Whether ASC MHL v2 or the older MHL v1 is the default target
- How resume-after-interruption stores its state
