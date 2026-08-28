# Vaultline Ingest 0.3.0 — implementation and qualification receipt

Date: 2026-08-27 (America/Los_Angeles)

Task: VLP-415

Branch: `codex/vlp-415-labs-ingest`

## Product identity

The first public Vaultline Labs Ingest binary is ingest-only. It opens directly into the card
offload journey and has no Drives registry, Drive Passport, Media Nexus, Relay, account, telemetry,
update checker, or network client. The app sandbox has no network client or server entitlement.

## Automated evidence

`xcodebuild test` passed 36 of 36 native tests on macOS 26.3.1 / Apple Silicon. Coverage includes:

- portable configuration validation, import/export, defaults, tokens, dates, safe paths, and real
  Premiere-template behavior;
- configured job structure and media landing;
- two-destination fan-out and read-back verification;
- matching-file restart without rewrite;
- different-file conflict without overwrite;
- cooperative cancellation with no partial final file;
- abandoned staging cleanup on restart;
- unavailable destination failure without source mutation;
- destination-inside-source, overlapping-destination, duplicate-output-plan, linked-folder escape,
  and insufficient-capacity rejection before copying;
- hidden camera metadata retention while Finder, AppleDouble, Spotlight, filesystem debris, and
  source symlinks are excluded;
- source modification-date preservation and atomic, no-replace manifest/record publication;
- streamed xxHash64, MD5, and SHA-1 canonical vectors; and
- ASC MHL destination paths, selected hash algorithm, transfer semantics, and resumed-file hashes;
- team-and-form-namespaced persistence for valid fields explicitly configured to carry over; and
- rejection of stale automatic dates, non-sticky card fields, invalid choices, blank values, and
  answers from another team's configuration during restoration.

## Build evidence

The 0.3.0 build 7 Release configuration built as a universal `arm64` + `x86_64` macOS app. The
review package is ad-hoc signed, passes strict `codesign` verification, and is sandboxed. Its only
entitlements are the sandbox, user-selected read/write, and app-scoped bookmarks; it has no network
entitlement or development-only `get-task-allow` entitlement.

Installed review build:

`/Applications/Vaultline Ingest 0.3 Review 7.app`

Review DMG SHA-256:

`1198b5c6a49db72c57f26df44865cacd6a03c493dada0f2279c83bfa17f0919e`

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

## Clean-Mac package exercise

The exact build 7 DMG was copied to dedicated test device `VL-Mini-02` (macOS 26.6.2, Apple
Silicon). Its SHA-256 matched, the app installed outside the DMG, passed strict signature
verification, was confirmed universal, reported version 0.3.0 build 7, exposed only the three
intended entitlements, and launched as a running process. The machine had no physical camera card
or external destination attached. Its existing GUI session was locked against remote input, so a
clean-Mac UI offload is `not_run`, not a passing claim.

## Standards correction

The inherited manifest writer incorrectly described an offload as `in-place`, labeled initial
hashes as `verified`, and wrote a non-schema root-hash shape. The 0.3.0 writer now emits a standalone
ASC MHL `transfer` manifest, labels initial hashes `original`, omits the optional root hash rather
than inventing one, writes destination-relative paths, and never replaces an existing manifest.

## Remaining release boundaries

Before public distribution: independent exact-diff review, a physical-card/external-volume exercise
including a real cable disconnect, Developer ID signing, notarization/stapling, public hosting, and
a real team's configuration. Those are not claims made by this receipt.
