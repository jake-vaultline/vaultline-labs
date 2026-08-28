# Vaultline Ingest 0.3.0 — implementation and qualification receipt

Date: 2026-08-27 (America/Los_Angeles)

Task: VLP-415

Branch: `codex/vlp-415-labs-ingest`

## Product identity

The first public Vaultline Labs Ingest binary is ingest-only. It opens directly into the card
offload journey and has no Drives registry, Drive Passport, Media Nexus, Relay, account, telemetry,
update checker, or network client. The app sandbox has no network client or server entitlement.

## Automated evidence

`xcodebuild test` passed 45 of 45 native tests on macOS 26.3.1 / Apple Silicon. Coverage includes:

- portable configuration validation, import/export, defaults, tokens, dates, safe paths, and real
  Premiere-template behavior;
- configured job structure and media landing;
- two-destination fan-out and read-back verification;
- matching-file restart without rewrite;
- different-file conflict without overwrite;
- cooperative cancellation with no partial final file;
- abandoned staging cleanup on restart;
- unavailable destination failure without source mutation;
- destination disappearance during a staged copy with no partial final file, followed by a safe
  reconnect/retry that verifies the original source bytes and removes staging debris;
- source size or modification-time drift during copying, which fails without publishing a final
  file or retaining staging debris;
- destination-inside-source, overlapping-destination, duplicate-output-plan, linked-folder escape,
  and insufficient-capacity rejection before copying;
- hidden camera metadata retention while Finder, AppleDouble, Spotlight, filesystem debris, and
  source symlinks are excluded;
- source modification-date preservation and atomic, no-replace manifest/record publication;
- streamed xxHash64, MD5, and SHA-1 canonical vectors; and
- ASC MHL destination paths, selected hash algorithm, transfer semantics, and resumed-file hashes;
- team-and-form-namespaced persistence for valid fields explicitly configured to carry over; and
- rejection of stale automatic dates, non-sticky card fields, invalid choices, blank values, and
  answers from another team's configuration during restoration; and
- immutable Start-time capture of resolved answers, automatic date, checksum, manifest, and form
  settings, so a long-running card's receipt cannot drift from the transfer that actually ran; and
- truthful per-destination receipt wording for written, disabled, and failed/not-written MHL
  outcomes, without mislabeling output failures as media-verification failures; and
- change detection across every persisted naming property used to invalidate and rebuild an active
  source plan after a team-configuration import or naming edit; and
- natural singular and plural result grammar for one-file and multi-file completed runs; and
- cancellable source discovery with no partial-plan publication, while the packaged app performs
  the filesystem walk and deterministic sort outside the UI actor.

## Build evidence

The 0.3.0 build 16 Release configuration built as a universal `arm64` + `x86_64` macOS app. The
review package is ad-hoc signed, passes strict `codesign` verification, and is sandboxed. Its only
entitlements are the sandbox, user-selected read/write, and app-scoped bookmarks; it has no network
entitlement or development-only `get-task-allow` entitlement.

Installed review build:

`/Applications/Vaultline Ingest 0.3 Review 16.app`

Review DMG SHA-256:

`5e5b8a4e346907b4cac075528888eac9896bcd09969a54b6d983d9ff69a525ab`

This is a local review artifact, not a notarized or public release.

## Visible product exercise

The build 5 app was exercised through its actual macOS UI with read-only ExFAT
camera-card and writable ExFAT destination images:

1. First launch opened directly into “Drop a card or folder here,” with no product/account chooser.
2. The configured-job sheet displayed the useful default brief and rejected `2026-8-27` with the
   exact `YYYY-MM-DD` correction.
3. `2026-08-27`, shooter `Jordan Lee`, and project `Launch Film B` previewed
   `01 Shoots/260827_Launch Film B`, the complete folder tree, the exact camera-media landing folder,
   and the absence of a fabricated Premiere file.
4. Job creation produced the previewed tree and no `.prproj` without a real configured template.
5. The read-only card contained two camera files, one valuable hidden camera metadata file,
   `.DS_Store`, and ExFAT AppleDouble debris. The plan showed exactly the three intended files.
6. Ingest copied and read back those three files and reported 3 of 3 verified. Its MHL named only
   those three relative paths.
7. Independent SHA-256 checks matched all three source/destination pairs. Checks over all 12 files
   on the source volume, including filesystem metadata, confirmed the read-only card was unchanged.
8. Destination modification timestamps matched their source files exactly.
9. The plain-text ingest record contained the operator brief, destination, counts, algorithm, and
   per-file xxHash64 values.
10. The generated standalone ASC MHL shape is covered by the same official-reference-XSD tests used
    for the prior receipt; builds 5 and 6 changed publication atomicity and source planning, not the
    schema.
11. After quitting and relaunching, selecting the card restored the exact configured media landing
    folder through its security-scoped bookmark. Re-running copied zero media bytes, reported all
    three files already present and matched, and did not rewrite them.
12. Detaching the virtual destination caused its saved image to be reattached through bookmark
    resolution; the subsequent run again verified the existing files without rewrite.
13. Replacing one disposable destination file with different bytes produced a visible name clash;
    the app reported the exact path and left the conflicting bytes unchanged.
14. The exact build 7 package ran the same card against the existing verified destination and
    reported three of three files already matched with zero KB copied. After quitting and
    relaunching, it restored shooter `Jordan Lee`, location `Portland Studio`, subject
    `Launch Film B`, camera `Sony FX6`, the automatic current date, and the exact destination.
    The non-sticky card/reel field remained blank and Start Ingest was enabled without retyping the
    brief.
15. The exact build 8 package copied and verified a disposable 12.88 GB synthetic card, then ran it
    again with zero KB copied and the existing file reported as matched. During both copy and
    verification, source changes, Naming Setup, job/destination changes, and every brief field were
    unavailable; the brief rendered as immutable values rather than editable controls. An attempted
    Notes mutation against the superseded package did not enter the receipt because the Start-time
    snapshot was already fixed. The final package exposes no editable Notes control during a run.
    Its ingest record retained the original date, shooter, location, subject, and camera values.
16. In the exact build 9 package, MHL was disabled through the real Settings UI and a two-file
    read-only-card subfolder was ingested and verified. The new destination receipt stated
    `Manifest disabled by team configuration`, contained no false alongside-manifest claim or
    `DID NOT VERIFY` heading, and the run created no new MHL. The normal MHL preference was restored
    afterward and the app was left open at its first card/source screen.
17. With a two-file source already selected in the exact build 10 package, importing a team package
    that enabled renaming and changed the file template to `{code}_{seq:0000}` immediately rebuilt
    the existing plan. The live UI changed `A001.mov` and `A002.mov` to `QUAL_0001.mov` and
    `QUAL_0002.mov` without reselecting the source or relaunching. Importing the normal configuration
    immediately removed the rename preview. A subsequent full-card run verified all three existing
    files without rewriting them; after quit/relaunch, the configured carry-over brief restored
    `Jordan Lee`, `Portland Studio`, `Launch Film B`, and `Sony FX6` under the active form schema.
18. The exact build 13 package visibly scanned a synthetic 500,000-file card without blocking the
    main window. It showed `Scanning card…` and `Scanning the source without blocking the app…`,
    kept `Change` available, and disabled Start and rename changes until the plan was complete.
    Choosing `Change` cancelled the obsolete scan immediately: the app process dropped from full
    CPU to idle while the system picker remained open. Selecting a two-file replacement source
    published exactly `2 files · Zero KB`; after the original scan would otherwise still have been
    running, the UI remained on that replacement plan and never published a partial or stale result.

## Clean-Mac package exercise

The exact build 16 DMG was copied to dedicated test device `VL-Mini-02` (macOS 26.6.2, Apple
Silicon). Its SHA-256 matched, the app installed outside the DMG, passed strict signature
verification, was confirmed universal, reported version 0.3.0 build 16, exposed only the three
intended entitlements, and launched as a running process. The machine had no physical camera card
or external destination attached. Its existing GUI session was locked against remote input, so a
clean-Mac UI offload is `not_run`, not a passing claim.

## Build 14 operator corrections

The source picker now treats file packages as directories, so camera-card package folders such as
RED `.RDC` clips are directly selectable as ingest sources. Configurable destinations also expose
their remove control persistently rather than only on pointer hover, with an explicit accessibility
label and help text. These changes compiled, passed the full suite and static analysis, and are in
the exact package above; no visible UI-exercise claim is made for them.

## Build 16 safety and configuration corrections

Configured-job creation now preflights the complete folder tree and rejects a regular file occupying
any configured directory path before creating anything else. A source whose size or modification
time changes during copying now fails safely before any final media file is published. Team packages
may leave `parentSubpath` empty when the correct workflow creates the job directly under the selected
destination. Form-field reorder and removal controls are persistent and accessibility-labeled.
These paths pass focused regressions, the full native suite, Release static analysis, and the exact
package checks above; no new visible UI-exercise claim is made for them.

## Standards correction

The inherited manifest writer incorrectly described an offload as `in-place`, labeled initial
hashes as `verified`, and wrote a non-schema root-hash shape. The 0.3.0 writer now emits a standalone
ASC MHL `transfer` manifest, labels initial hashes `original`, omits the optional root hash rather
than inventing one, writes destination-relative paths, and never replaces an existing manifest.

## Remaining release boundaries

Before public distribution: independent exact-diff review, a physical-card/external-volume exercise
including a real cable disconnect, Developer ID signing, notarization/stapling, public hosting, and
a real team's configuration. Those are not claims made by this receipt.
