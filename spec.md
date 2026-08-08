# Vaultline Inspector — Product Spec

**Status: BUILD STARTED 2026-08-07.** Milestone 1 (Pass 1 + live results) written,
not yet compiled — see `app/README.md`.

**Name: Vaultline Labs Drive Inspector** (decided 2026-08-07).
Bundle ID `com.vaultline.labs.driveinspector`. Menu-bar `CFBundleName` is shortened to
"Drive Inspector" since the full name doesn't fit — full name lives in
`CFBundleDisplayName`. Worth a `vaultline-brand` check, since putting "Labs" in a
product name effectively debuts Labs as a public sub-brand via this app.

---

## 1. What it is

A tiny free Mac app. Drag a folder onto it or pick a drive. It scans **locally**,
nothing uploads, and it gives you an X-ray of what's actually sitting on that storage.

Point it at a 40TB RAID and find out what's on there — which is a question most teams
genuinely cannot answer today.

## 2. Why this one first

- **Nothing to buy to try it.** No hardware, no account, no trial.
- **It demos indexing** — which is what Vaultline actually sells.
- **It self-selects the buyer.** Useless on 2 drives, revelatory on 200. Exactly the
  filter described in `../../charter.md`.
- **It's a piece of Relay/Archive escaped into the wild.** The philosophy communicates
  itself: *we make your existing media infrastructure understandable.* No pitch needed.

## 3. The output

### Header
```
SAMSUNG T7 — 3.84 TB
2.71 TB used · 14,382 media files · 126 projects detected
```

### Breakdown
- **By type** — video / photo / audio: file count, size, total duration
- **Top codecs** — % share (ProRes 422 HQ, H.264, XAVC, …)
- **Resolutions** — % share (4K / 6K / 1080p / other)
- **Frame rates**
- **Date range** — earliest → latest media
- **Storage by codec**
- **Total duration**

### The interesting stuff
- **Cameras detected** — Sony FX6 · FX3 · Canon R5C · DJI Mavic 3
- **Largest folders** / **largest files**
- **Folder tree visualization**
- **Potential duplicates**
- **Empty folders**
- **Project files detected**
- **Media age** distribution
- **Estimated proxy storage required**

### Export
**Export Report → PDF / CSV** (plus HTML — see §7, this matters more than it looks)

### The bridge
> Want this visibility across all your storage, all the time?
> Vaultline automatically indexes your team's storage and makes it searchable without
> moving your original media.

---

## 4. Architecture: three passes, results stream in

**This is the single most important design decision.** A 40TB RAID scan that takes an
hour before showing anything gets cancelled at minute three and never reopened. Speed
isn't a feature here, it's the product.

### Pass 1 — filesystem walk (fast, seconds to ~2 min)

Metadata only, no file contents opened. Yields roughly 70% of the output above:

file counts · sizes · dates · extensions · folder tree · largest files and folders ·
empty folders · project files detected · media age · type breakdown by extension

**Render this immediately and progressively.** The user should see the header populate
within seconds and watch numbers climb. That's the moment that sells the app.

*Target: 500k files in under 2 minutes over Thunderbolt.*

### Pass 2 — media probe (the slow one)

Opens each media file's container header. Yields codec, resolution, frame rate,
duration, camera metadata, storage-by-codec, proxy estimate.

Stream results as they arrive, sorted so the biggest files resolve first — the summary
percentages stabilize early even at 20% complete. Let the user export at any point with
a clear "based on N of M files scanned" note.

Cache by `(path, size, mtime)` so a rescan is near-instant. Rescanning the same drive
next month should take seconds.

### Pass 3 — duplicates (opt-in, run last)

Never hash 2.7TB. Tiered:

1. Group by exact file size — most files have no size twin, eliminated for free
2. For size-collision groups only, hash first 1MB + last 1MB
3. Full hash only when the partial hashes also collide

Near-instant in practice and accurate enough to label "potential duplicates," which is
the honest framing anyway.

---

## 5. The technical forks worth deciding now

### Media probing: AVFoundation, not bundled ffmpeg

**Recommendation: AVFoundation / `AVAsset`.**

| | AVFoundation | Bundled ffprobe |
|---|---|---|
| ProRes, H.264, HEVC, XAVC | native, hardware-accelerated | yes |
| Bundle size | zero | tens of MB |
| Licensing | none | LGPL/GPL obligations on a distributed binary — real, avoidable friction |
| Notarization | clean | extra signing surface for the bundled binary |
| R3D / ARRIRAW / BRAW | ✗ | ✗ without vendor SDKs |

Neither handles camera-raw formats. For those, fall back to sidecar files, folder
structure, and filename patterns, and label them as detected-by-convention rather than
probed. Under-claiming is fine; being confidently wrong is not.

### Camera detection — this is the "wow" feature, prioritize it

Nobody expects the app to know their camera bodies. It's the most screenshot-able line
in the whole report and therefore the most valuable one for distribution.

Sources, in order of reliability:

1. **QuickTime/MP4 metadata atoms** — many cameras write make/model directly
2. **Vendor sidecar XML** — Sony writes per-clip XML; RED/ARRI have their own
3. **Folder structure** — `XDROOT` and `PRIVATE/M4ROOT` (Sony), `DCIM` (stills),
   `CLIP`/`SUB` conventions
4. **Filename patterns** — `C0001.MP4` (Sony), `A001_*.braw`, DJI conventions
5. **EXIF via ImageIO** for stills

Ship with a maintained mapping table. Getting this right on the top 15 bodies used in
production covers the overwhelming majority of real drives.

### "126 projects detected" — the riskiest number in the report

This is the claim most likely to be wrong, and a wrong number here discredits everything
above it. Someone whose structure doesn't match the heuristic sees "126" next to their
actual 12 and closes the app.

**Base it on detected project files first** — `.prproj`, `.fcpbundle`, `.drp`, `.aep`,
`.braw`-adjacent project dirs. Where only folder heuristics are available, say so:
*"126 project folders detected (by structure)"*. Two different labels, honestly used.

---

## 6. The privacy claim has to be provable, not just stated

"Nothing gets uploaded" is the core promise, and somebody in this audience *will* run
Little Snitch on it. A single unexplained network call costs more trust than the app
earns.

**Decision (2026-08-07): ship with no network entitlement.**

### Correction — the entitlement only means something if the app is sandboxed

An earlier draft of this spec said "no network entitlement" while assuming a
non-sandboxed app. That doesn't hold up. **Outside the App Sandbox, entitlements do not
restrict network access** — a non-sandboxed app can open sockets regardless of what its
entitlements file says. The claim would have been social, not technical, and anyone
who checked carefully could have called it out.

**So: sandbox the app.** Final permission model:

```
com.apple.security.app-sandbox                    = true
com.apple.security.files.user-selected.read-only  = true
(no network entitlement of any kind)
```

This is strictly better in three ways:

1. **The privacy claim becomes enforceable and checkable** by anyone who inspects the
   binary. That's the whole point.
2. **Full Disk Access is no longer needed.** The user dragging in a drive *is* the grant
   (via powerbox / security-scoped access). §9's TCC onboarding problem largely
   disappears — a real reduction in first-run friction, which was the biggest risk to
   a lead-magnet app.
3. **Sandboxing does not require the Mac App Store.** Developer ID distribution with a
   sandboxed app is entirely normal.

Cost: the app can only ever see what the user explicitly hands it. For this tool that's
correct behavior, not a limitation.

The marketing line survives, and now it's true in the strong sense:

> We didn't just promise not to upload your data. The app is sandboxed and never
> requested network permission at all — check the entitlements yourself.

**Trade-off accepted:** no Sparkle auto-update in v1. Users re-download to upgrade. Add
updating later in a separate signed helper, or once the claim has done its work.

---

## 7. The report is the real marketing surface

The app gets used once per drive. **The exported report gets emailed to a producer,
pasted into Slack, and shown in a meeting.** Vaultline's name travels with it, into
exactly the rooms where the buying decision happens.

So the export is not a checkbox feature — it's the distribution mechanism.

- **PDF** — branded per `vaultline-brand`, genuinely beautiful. Treat it as a designed
  document, not a data dump
- **HTML, single self-contained file** — the one that gets pasted into Slack and opened
  by six people. Arguably the highest-leverage format of the three
- **CSV** — for the person who wants to pivot it themselves

Footer on every export carries the bridge copy from §3.

---

## 8. v1 scope vs. later

Ship-blocking discipline: his full list is a v2. Cut to what makes the first impression.

**v1 — everything from Pass 1 + the high-value probe results:**

header · type breakdown · codecs · resolutions · frame rates · date range · total
duration · largest files and folders · cameras detected · project files detected ·
empty folders · export (PDF/HTML/CSV)

**v1.1 — cheap additions:**

media age distribution · storage by codec · estimated proxy storage · potential
duplicates

**v2 — expensive to do well:**

folder tree visualization (easy to build badly; a bad one looks worse than none) ·
multi-drive comparison · scheduled rescans · watch folders

**Never in the free app** — these are the paid product: search, tagging, transcripts,
cross-drive index, anything persistent.

---

## 9. Permissions and first-run

**Largely solved by the sandbox decision in §6.** Because the app is sandboxed with
`files.user-selected.read-only`, the act of dragging in a drive or picking one in the
open panel *is* the permission grant. No Full Disk Access prompt, no TCC onboarding
flow, no System Settings deep link, nothing to explain.

That removes what would otherwise have been the single largest first-run risk. A free
app that appears broken before it does anything is fatal, and this design sidesteps it
entirely.

Remaining care:

- Hold the security scope open for the duration of the walk
  (`startAccessingSecurityScopedResource` / `stop…`), or long scans fail partway
- If scan-history or rescan lands later, it needs security-scoped **bookmarks** —
  a plain stored path won't reopen after relaunch
- Still test on a machine that has never run the app. The developer's own Mac hides
  first-run bugs

---

## 10. Open / undecided

- ~~Name~~ — **decided: Vaultline Labs Drive Inspector**
- ~~Network posture~~ — **decided: sandboxed, no network entitlement** (§6)
- Whether v1 ships with duplicates or defers to v1.1
- Whether the report asks for an email before export (leans **no** — friction against a
  distribution asset), or offers it optionally after
- Swift/SwiftUI native vs. anything cross-platform — leans native, since AVFoundation and
  the TCC flows are the whole app
- Whether R3D/ARRIRAW/BRAW support is ever worth vendor SDK integration
- Where downloads are hosted
