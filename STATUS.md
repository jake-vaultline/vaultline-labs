# Drive Inspector — is it ready to ship?

**Version 0.2 source candidate: all 0.1 inventory/probe/export capability retained,
with exact-content duplicate verification promoted as the first actionable result.
Not signed, notarized, published, or deployed.** Updated 2026-08-21 under VLP-206.

---

## Done

| | |
|---|---|
| ✅ **UI** | Drop zone, live results, cancellation, export menu |
| ✅ **Pass 1 — filesystem walk** | Types, formats, recursive folder sizes, largest files, date range, empty folders, project detection |
| ✅ **Pass 2 — media probe** | Codecs, resolutions, frame rates, duration, cameras, embedded capture dates. AVFoundation + ImageIO, headers only, 6-way concurrent, biggest-file-first |
| ✅ **Report export** | HTML, PDF, CSV. One HTML source; the PDF is that HTML printed via WKWebView, so they can't drift |
| ✅ **App icon** | Charcoal squircle + VL monogram, all 7 sizes |
| ✅ **Permission model** | Sandboxed, user-selected read-only, no network entitlement |
| ✅ **Release pipeline** | `release.sh` — archive → sign → entitlement guard → DMG → notarize → staple ×2 → verify |
| ✅ **Pass 3 — duplicates** | Size grouping → partial hash (first + last 1 MB + size) → full SHA-256 for every surviving collision. Only full-content matches count as reclaimable. 4 MB floor; 24 GB verification passes pause with explicit Continue and exact partial totals |
| ✅ **Download page** | `download/index.html` |

## Before it goes public

| | |
|---|---|
| ✅ **Compiled** | Done 2026-08-07. Two bugs in `MediaProbe.swift`, both in the `AVAsync` metadata path as predicted — see `../../AUDIT.md` §4 |
| ✅ **Team ID** | `57U2N6J9ZS`, in both `ExportOptions.plist` and `project.yml`. Release-config signing changed to manual + `Developer ID Application` — no "Apple Development" cert exists on this Mac, only Developer ID, which is the one that matters anyway |
| ✅ **Signed, notarized, stapled DMG** | `build/VaultlineLabsDriveInspector-0.1.0.dmg`, 1.0 MB. Both the `.app` and the DMG itself carry tickets — `stapler validate` passes on both. (The DMG needed its own second `notarytool submit`: rebuilding it around the freshly-stapled app produces a new file the first submission's ticket doesn't cover — the "why staple twice" note in `app/RELEASE.md` undersells this; it's actually submit-notarize-staple twice for the DMG layer specifically) |
| ✅ **End-to-end verified as a real download** | Copied the built app out with a `com.apple.quarantine` xattr set (`Safari` origin, exactly what a browser download looks like), then ran it via `open`. `spctl` accepted it as `Notarized Developer ID` and it launched with **zero Gatekeeper dialog** — no right-click-Open dance |
| ✅ **Full scan + report export re-verified on the quarantined build** | Ran a real scan on `SANDBOX-VOLUME-01` (2 TB, 1,647 files) through the exact binary a user would get, exported the HTML report, confirmed 2 `data:image` logos inlined and zero external `http` refs — offline-safe |
| ❌ **Hosting** | Nowhere to put the DMG yet — see the conversation this update came from for options |
| ❌ **Real-drive testing** | Narrower than it was — see below. `SANDBOX-VOLUME-01` covered "large real messy drive" and "vertical/mixed footage" in passing, but not the specific edge cases listed (FCP bundle, camera card structure, permission-denied subfolder, network volume, never-run-before Mac) |

---

## UI/UX pass — 2026-08-08, from Jake's first look at the running app

Nine items from direct feedback, plus two more bugs caught while re-testing each fix
against `SANDBOX-VOLUME-01`. All in the DMG built same day.

| Item | What changed |
|---|---|
| Title bar logo | Was the full company wordmark (icon + "Vaultline" + tiny "SOLUTIONS" subtext) squeezed to 17pt — illegible, and crowded "Drive Inspector" into looking like part of the same logo. Now the icon mark alone, a divider, and "Drive Inspector" in full-contrast ink instead of dim steel |
| Drop-zone footer | Removed "This app has no network permission at all. Check the entitlements yourself." |
| Report masthead | Removed "nothing left this Mac" from the meta line |
| Domain | `vaultline.io` → `vaultlinesolutions.com`, in `ReportBuilder.swift`, `report-template.html`, and `download/index.html` |
| Report polish | Reviewed the actual generated HTML (not just the template) end to end |
| Duplicate detection in-app | Was aggregate-only (a stat + a notice banner). Now the primary "Verified duplicates" result — exact full-content groups, reclaimable bytes, expandable paths, reveal-in-Finder per file, and explicit paused/unreadable/changed/cancelled exclusions |
| Reveal in Finder | New — header "Reveal in Finder" for the scanned root, plus per-row on largest files/folders and duplicate paths, via `NSWorkspace.activateFileViewerSelecting` |
| CSV export | Was one ambiguous `Section,Key,Count,Bytes` table where the same column meant different things per row, stitched to several ad hoc tables. Rewritten as one cleanly-headered table per section |
| PDF export | Was silently broken — `WKWebView` was never attached to a window, which is a known cause of blank/truncated `.pdf(configuration:)` output. Now hosted in an offscreen borderless `NSWindow` before rendering. Verified: real multi-page content extracts with `pdftotext`, not a blank page |
| R3D probing — corrected | First pass added a timeout to `MediaProbe.probeAV`, guessing the R3D complaint was a hang. **It isn't.** The `SANDBOX-VOLUME-01/25-031_Camera-Test-Library/.../NON_PLAYABLE_RAW_REVIEW/` files named `*.R3D.probe-failed` turned out to be real RED KOMODO/V-RAPTOR footage (`RED2` magic bytes, 1.8–3.5 GB each, genuine Chrome-downloaded quarantine xattrs from 2025) — someone had already renamed them once to keep them out of the pipeline. Tested the actual shipped `probeAV` directly against one: it returns in **7ms**, not a hang, with `codec: nil, resolution: nil, duration: 0.0` — AVFoundation opens the container and extracts nothing. That result was previously silent: the file still counts as "Video" by extension and its bytes count toward the total, but contribute zero to codecs/resolutions/duration, so those breakdowns quietly stop summing to the video total with no explanation. Fixed for real: `ProbeSummary.unreadable` now tracks files where the probe found nothing, surfaced as a notice in both the app (`ResultsView.attention`, previously an empty stub) and the report's "Worth a look" section — "N files couldn't be read for codec, resolution or duration... often RAW formats like R3D or BRAW." The timeout guard stays in (defensive, costs nothing) but the real fix is this |
| Largest folders always led with the root | *(found while re-testing, not in Jake's list)* Every file's bytes are credited up to and including the scan root, so the root was always the #1 "largest folder" at a guaranteed 100% — zero information, and it bumped a real folder out of the top 10. Now filtered out of the ranking |
| "1 files" | *(found while re-testing)* Camera/folder/duplicate counts read "1 files" for singular counts. Added `Fmt.files(_:)` and applied it at all 6 call sites where it mattered (top-line "N files scanned" counters left as-is — a 1-file top-level scan isn't a realistic case) |

---

## What changed about the "no verified second copy" line

**Cut from the app.** A single-drive scan cannot know what exists elsewhere, and the
number would have been fabricated. `ReportBuilder.attentionBlock` carries a comment
saying so, to stop it being helpfully re-added later.

It stays as the sharpest argument for the paid product: cross-drive backup verification
is exactly what a single free tool structurally cannot do. The bridge copy in the report
footer now earns its place rather than asserting it.

---

## Testing that actually matters

The developer's own Mac hides most of these. Test on a real messy drive:

- **FCP library containing media** — the walker descends into `.fcpbundle` on purpose.
  Does the media count look right, and is the library also counted once as a project?
- **Camera card structure** — `XDROOT`, `PRIVATE/M4ROOT`, `DCIM`. Does camera detection
  fire, and does it say "(card structure)" when it's a guess rather than metadata?
- **A cloned or copied drive** — do capture dates come from metadata? If under half the
  files carry one, the report must say the timeline is from file dates. Verify that
  sentence appears
- **Permission-denied subfolders** — the walk should skip and continue
- **A network volume** — is the UI responsive, does Stop actually stop, is Pass 2
  tolerable at 6-way concurrency over the wire?
- **Vertical clips** — `preferredTransform` is applied; a 4K vertical must not file as
  1080p
- **A Mac that has never run the app**
- **Export all three formats** and open the HTML on a machine with no network — if a
  logo is missing, something stopped being inlined

---

## Critical path

1. ~~Build in Xcode, fix compile errors~~ — done 2026-08-07
2. Test against the list above — **still open**, the real remaining risk
3. ~~Fill in Team ID~~ — done 2026-08-07
4. ~~`./release.sh`~~ — done 2026-08-07, signed + notarized + stapled DMG in hand
5. Host the DMG, publish the download page — next

Step 2 is where the surprises live.

---

## Static audit — fixed before first build

A read-through of the Swift caught things that would have failed to compile or been
quietly wrong. Recorded so the same mistakes aren't reintroduced:

| Issue | Fix |
|---|---|
| `ForEach(rows, id: \.name)` over arrays of labelled tuples | **Swift has no key paths into tuple components.** Every ranked breakdown now returns `[StatRow]`, a real Identifiable struct |
| `try? await item.load(.stringValue)` assigned to `String?` | `load` already returns an optional and `try?` wraps it again — the result is `String??`. Now peeled with `if let` |
| `<main>` opened in the capacity block, closed in the attention block | Either block can return empty on a real drive, producing broken HTML. Both moved to the top-level builder |
| Nested `"""` literals inside string interpolation | Fragile to parse and easy to break. Report HTML is now built by concatenation |
| Security scope released after Pass 2 | Would have made every Pass 3 read fail. Now held until the last pass finishes |

## The rule to hold

**The download page and the app must claim the same things.** The page's duplicates
claim is now true — Pass 3 exists — so it's back. Keep them in sync every release. A
free tool that over-promises does more damage to a company selling trust in media
infrastructure than shipping late ever would.

---

## Report, app and CSV parity pass — 2026-08-27, VLP-491

From Jake's read of a real 2 TB export. Six things, one of them a rendering bug
that had been shipping since 0.1.

### The bars never rendered

`.bar .fl` is an `<i>`. It carried `height:100%` and an inline `width:` but no
`display:block`, so it stayed an inline box, both dimensions were ignored, and
every bar in **What's on it**, **Codecs** and **Resolutions** drew as an empty
grey track. The capacity bar, the folder mini-bars and the year columns were all
fine, because each of those sets `display:block` explicitly — which is exactly
why nobody caught it by eye. One declaration; `testBarFillIsABlockSoItActuallyRenders`
now guards it.

Codecs and resolutions also gained a figure under each bar. "17% H.264" does not
tell a producer whether that is four clips or four hundred.

### "COPIESRECLAIMABLE"

`td` and `th` had zero horizontal padding, so two right-aligned numeric columns
butted straight into each other and the duplicates table header read as one word.
Now `th+th,td+td{padding-left:26px}`, with `overflow-wrap:anywhere` on paths so the
first column gives rather than crushing the numbers.

### The app showed less than the file it exported

The two surfaces had drifted badly:

| | Was in the app | Was in the report |
|---|---|---|
| Duplicate groups | 25, "see the exported report for the full list" | **10** |
| Cameras | 5 | 10 |
| Frame rates | absent | 8 |
| Media by year | absent | all |
| Worth a look | 1 of 4 items | 4 |
| Top formats | 12 | absent |
| Largest folders / files | 10 / 10 | 10 / 10 (of 25 / 100 kept) |

Every limit now lives in `Show` (`Models.swift`) and both surfaces read it. The
window gained frame rates, media by year, the full Worth a look block and a
wrapping camera grid; the report gained Top formats. Section order is identical
in both. Anything either surface leaves out says so, with the count, and points
at the CSV.

### The CSV was not what its own menu item said

The export menu had offered "CSV — every file, for your own analysis" since 0.1
and shipped aggregates plus the largest 100. It now carries a real `All files`
inventory, sourced from a new `MediaIndex.all` — deliberately not on
`ScanSnapshot`, which is copied and republished several times a second. Capped at
`Walker.maxMediaRefs` and it says so in-table when the cap is hit.

Also: UTF-8 BOM so Excel stops mojibaking camera names, human-readable sizes and
share percentages beside every byte column, project files and full empty-folder
and duplicate listings, an honest scan-state block, and **unquoted numerics** —
a quoted `"16000000"` imports as text and every `SUM` over the column silently
returns zero.

### Copy

No em dashes in report prose, the app's status strings, or the export filenames.
The `—` glyph still stands in for a missing value in a stat tile; that is a
placeholder, not prose. Footer drops the `$499`, the `vaultlinesolutions.com`
line and "scanned locally, never uploaded", and leads with the outcome rather
than the price.

### Still open

- **The download page says "Likely duplicate files."** The app verifies by full
  SHA-256 and says so. Per the rule above the page should say "verified", but
  editing it is outreach copy and out of this task's scope.
- Real-drive testing (the list above) is still the standing gap.
