# Vaultline Ingest 0.3.0 — implementation and qualification receipt

Date: 2026-08-27 (America/Los_Angeles)

Task: VLP-415

Branch: `codex/vlp-415-labs-ingest`

## Product identity

The first public Vaultline Labs Ingest binary is ingest-only. It opens directly into the card
offload journey and has no Drives registry, Drive Passport, Media Nexus, Relay, account, telemetry,
update checker, or network client. The app sandbox has no network client or server entitlement.

## Automated evidence

`xcodebuild test` passed 27 of 27 native tests on macOS 26.3.1 / Apple Silicon. Coverage includes:

- portable configuration validation, import/export, defaults, tokens, dates, safe paths, and real
  Premiere-template behavior;
- configured job structure and media landing;
- two-destination fan-out and read-back verification;
- matching-file restart without rewrite;
- different-file conflict without overwrite;
- cooperative cancellation with no partial final file;
- abandoned staging cleanup on restart;
- unavailable destination failure without source mutation;
- destination-inside-source, overlapping-destination, and duplicate-output-plan rejection;
- streamed xxHash64, MD5, and SHA-1 canonical vectors; and
- ASC MHL destination paths, selected hash algorithm, transfer semantics, and resumed-file hashes.

## Build evidence

The 0.3.0 Release configuration built as a universal `arm64` + `x86_64` macOS app. The local review
build is ad-hoc signed, passes strict `codesign` verification, and is sandboxed. Its product
capabilities are limited to user-selected read/write plus app-scoped bookmark access; it contains
no network entitlement. The local review signature also includes Xcode's development-only
`get-task-allow` flag.

Installed review build:

`/Applications/Vaultline Ingest 0.3 Review.app`

This is a local review artifact, not a notarized or public release.

## Visible product exercise

The installed app was exercised through its actual macOS UI with a disposable two-file camera-card
tree and destination:

1. First launch opened directly into “Drop a card or folder here,” with no product/account chooser.
2. The configured-job sheet displayed the useful default brief and rejected `2026-8-27` with the
   exact `YYYY-MM-DD` correction.
3. `2026-08-27`, shooter `Jordan Lee`, and project `Launch Film` previewed
   `01 Shoots/260827_Launch Film`, the complete folder tree, the exact camera-media landing folder,
   and the absence of a fabricated Premiere file.
4. Job creation produced the previewed tree and no `.prproj` without a real configured template.
5. Ingest copied two nested card files, read them back, and reported 2 of 2 verified.
6. Independent SHA-256 checks matched source and destination files after the app completed.
7. The plain-text ingest record contained the operator brief, destination, counts, algorithm, and
   per-file xxHash64 values.
8. Both generated standalone ASC MHL manifests validated against the official ASC reference XSD.
9. Re-running the same card copied zero media bytes, reported both files already present and
   matched, and did not rewrite them.
10. Replacing one disposable destination file with different bytes produced a visible name clash;
    the app reported the exact path and left the conflicting bytes unchanged.

## Standards correction

The inherited manifest writer incorrectly described an offload as `in-place`, labeled initial
hashes as `verified`, and wrote a non-schema root-hash shape. The 0.3.0 writer now emits a standalone
ASC MHL `transfer` manifest, labels initial hashes `original`, omits the optional root hash rather
than inventing one, writes destination-relative paths, and never replaces an existing manifest.

## Remaining release boundaries

Before public distribution: independent exact-diff review, clean-Mac and physical-card/external-
volume qualification, Developer ID signing, notarization/stapling, public hosting, and a real team's
configuration. Those are not claims made by this receipt.
