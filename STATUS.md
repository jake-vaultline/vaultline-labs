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
| ✅ **Hosting** | **Solved, and this line was stale for weeks.** GitHub Releases on the public `jake-vaultline/vaultline-labs` repo, linked from the Vercel-hosted site. `v0.1.0` and `v0.2.0` are published and both return 200 |
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

---

## Follow-ons and 0.3.0 — 2026-08-27

Second pass on VLP-491, then a signed release.

| | |
|---|---|
| Download page claim | Said "Likely duplicate files". The app matches by full SHA-256 and says so, and STATUS's own rule is that the page and the app claim the same things. Now "verified byte for byte by full SHA-256 content hash, not guessed from name or size" |
| Download page version | Was still pointing at the 0.1.0 DMG at "about 4 MB" |
| Em dashes | Swept out of the download page too |
| `Show.years` | Defined for both surfaces but only the window used it, so the report and window could still disagree on the timeline. Both now take the most recent 20 and say how many years they dropped |
| `FileEntry.id` | Was a per-instance `UUID()`, which disagreed with the `==`/`hash` implementations right below it (both path-only) and cost 16 bytes on every entry — newly material now the walk keeps one per file for the CSV. Now the path |
| `Fmt.duration` | Reported "8 h" for eight hours forty-seven. It is a headline figure in both surfaces; now "8 h 47 min" |
| Top formats guard | The report dropped the section for a single-extension drive while the window rendered an empty heading. Both now key off the same condition |

### The PDF is one page 94 inches tall

Found while adding `PDFExportTests`. `Exporter.pdf()` uses
`WKWebView.pdf(configuration:)` with a default configuration, which snapshots
rather than paginates: a real report is a **single 860 × 6809 point page**. The
export menu offers it "for email and print". Because nothing ever breaks a page,
the `@media print` block and every `break-inside:avoid` rule in the stylesheet
have never done anything.

**Not fixed here, deliberately.** The obvious route,
`WKWebView.printOperation(with:)`, needs the `com.apple.security.print`
entitlement, which this app does not carry and should not gain in a rush — the
entitlement set *is* the privacy claim, and `release.sh` audits it. The attempt
hung and killed the test host. The sandbox-safe route is repeated
`pdf(configuration:)` calls with a page-sized `rect`, assembled into one
document, and that is a real change to an export path that deserves its own
task rather than being slipped in minutes before signing. Tracked as **VLP-496**.

`PDFExportTests` documents the current behaviour rather than blessing it, and
also guards the property that actually matters today: the PDF is not blank, it
carries every section and real figures, and the report still makes no external
requests.

### 0.3.0 shipped as a signed, notarized DMG — 2026-08-27

`./release.sh` end to end. Entitlement guard passed (sandboxed, no network
entitlement, user-selected files only). Notarized twice as the script intends,
both **Accepted** (`937639c6…`, then `19b23a3d…` for the repackaged image),
stapled on both the app and the DMG.

Verified as a real download rather than as a local build: copied the DMG out,
set a `com.apple.quarantine` xattr with a Safari origin, mounted it, and

- `spctl -a -t exec` → **accepted · source=Notarized Developer ID**
- `stapler validate` on the app inside the mounted image → passed
- launched from the quarantined mount with **no Gatekeeper dialog**, running
  under App Translocation exactly as a downloaded app does
- `CFBundleShortVersionString` → `0.3.0`

`build/VaultlineLabsDriveInspector-0.3.0.dmg`, **1.11 MB** (1,164,824 bytes),
staged into `download/` beside the page. `release.sh`'s closing line used to
quote `du`, which reported 2.1M for this same file; the download page quotes
the size a browser shows, so it now prints the apparent size.

**Not done: an interactive scan-and-export on the shipped binary.** The app
launched and drew its window, but another application kept taking keyboard
focus and driving the sandboxed file picker reliably was not worth forcing.
Everything the release pipeline can assert is asserted; what remains is the
30-second manual check — drag `SANDBOX-VOLUME-01` onto the window, let all
three passes finish, export HTML, PDF and CSV. The security-scope lifecycle and
the save panel were not touched by 0.3.0, so this is confirmation rather than
suspicion, but it is the one step still owed before the DMG is published.

### Hosting was never actually the blocker

The "nowhere to put the DMG" line above sat in this file for weeks after the
question had been answered. Hosting is **GitHub Releases on the public
`vaultline-labs` repo**, served through the Vercel site. `v0.1.0` and `v0.2.0`
are published; both URLs return 200.

Since VLP-490 (`repos/website`, 2026-08-27) the live `/drive-inspector` page no
longer contains a release URL at all. It posts the lead to `/api/download`,
which records it and only then returns the URL, version and SHA-256. Those three
values are environment variables:

| Variable | Currently defaults to |
|---|---|
| `DRIVE_INSPECTOR_VERSION` | `0.2.0` |
| `DRIVE_INSPECTOR_DMG_URL` | the `v0.2.0` release asset |
| `DRIVE_INSPECTOR_DMG_SHA256` | `9dfaad5d…bba32d` (verified to match the real 0.2.0 artifact) |

So publishing 0.3.0 needs **no code change**: cut the GitHub Release, then set
the three variables. Both are publication actions and wait on Jake.

`VaultlineLabsDriveInspector-0.3.0.dmg` SHA-256:
`9f21cc4b554c052a04d0e40a53d17a68c49e8c0f9dcd66f3047ded3119f73194`

### `download/index.html` in this repo is an orphan

It is not deployed, not referenced by anything, and duplicates the live page in
`repos/website/drive-inspector.html`. The claim and version fixes recorded above
were applied *to this orphan*, so the live page has not received them. It has no
stale claim to fix — VLP-490 rewrote it — but the duplication is a trap: the
next person to "update the download page" has an even chance of editing the one
nobody serves. It should be deleted or reduced to a pointer.

---

## 0.3.1 and 0.3.2 — the PDF export, 2026-08-27

Verifying the shipped 0.3.0 binary on a real drive found something the test
suite could not: **PDF export hangs.**

Everything else passed. The sandboxed, notarized build scanned
`SANDBOX-VOLUME-01` through all three passes, security-scoped access held, and
HTML and CSV both wrote correctly with the new sections, the per-file inventory,
the UTF-8 BOM and no em dashes. Then PDF export never returned: app idle at 0%,
WebContent idle at 0.7%, no error, and `Export Report` disabled until the app
was force quit.

### What it was, and what it was not

`pdf(configuration:)` with a default `WKPDFConfiguration` does not paginate; it
snapshots the whole document onto one page. A 0.2.0 report measured 860 × 6,809
points and survived that. Widening the report under VLP-491 to show every
duplicate group, 25 folders and 25 files pushed a real one past **11,000
points**, and WebKit stopped returning.

**0.3.1** rendered one page-sized `rect` at a time and assembled the slices, and
added a 90-second timeout so a stall could never wedge the UI again. In the test
bundle this is exact and fast: a fixture with 200 duplicate groups across 600
paths exports in **0.8 seconds**, where the old path hung. In the shipped,
sandboxed build it still hung — *and the timeout did not fire either*, which
means the failure is not simply a slow render. A `sample` showed the main thread
parked normally in its run loop, so the app was responsive; something in the
async chain never resumed. Not understood.

**0.3.2 removes PDF from the export menu.** A menu item that permanently
disables the export button is worse than one that is not there. `Format.offered`
carries the reasoning; the code and its tests stay, so restoring the item is a
one-line change once the hang is understood. Tracked as **VLP-496**.

Nothing is actually lost. The HTML is a single self-contained file, and Print to
PDF from any browser paginates it through the browser's own print engine, which
honours the `@media print` rules the stylesheet has carried since 0.1 and which
the app's own PDF path never used. That is a better PDF than this app was
producing. The menu label says so.

### Verified on the shipped 0.3.2 binary

Quarantined DMG, mounted, launched with no Gatekeeper dialog, under App
Translocation. Full scan of `SANDBOX-VOLUME-01`, then both exports:

- **HTML**, 71,317 bytes: bar fills present, all 12 sections, 0 em dashes, `0.3.2`
- **CSV**, 392,359 bytes: 2,271 rows including the full `All files` inventory, `0.3.2`
- `8 h 46 min` in the Footage tile, where every earlier build rounded to `8 h`

### Live, 2026-08-27

- **GitHub Release `v0.3.2`** on the public `vaultline-labs` repo, asset checksum
  `6caec7fb…127709`, byte-identical to the locally notarized build.
- **Vercel production** carries `DRIVE_INSPECTOR_VERSION`, `DRIVE_INSPECTOR_DMG_URL`
  and `DRIVE_INSPECTOR_DMG_SHA256`, and the deployment was promoted to
  `www.vaultlinesolutions.com`. No code change was needed; that is what VLP-490's
  endpoint was built for.
- **Full visitor path verified**: `/drive-inspector` returns 200, the email gate
  returns 0.3.2, the asset downloads at the expected checksum, and `spctl` accepts
  it as Notarized Developer ID with `CFBundleShortVersionString` `0.3.2`.

Hosting is GitHub Releases; the earlier "nowhere to put the DMG" note in this file
was stale.
