# Vaultline Labs Ingest — status

## Current VLP-415 source (0.3.0)

The app is being productized as a free standalone configurable ingest/offload utility. The current
task branch includes:

- a useful default ingest form for date, shooter, location, subject/project, camera, job number,
  card/reel, and notes;
- stable form tokens, automatic date rendering, and team-configured carry-over fields that persist
  safely across card changes, quits, crashes, and resumes without carrying card-specific or stale
  automatic values;
- an immutable Start-time brief and output-settings snapshot, with the visible brief and
  configuration controls locked during transfer so the final record cannot drift from the card
  that actually ran;
- a versioned portable team-configuration package with transactional validation and import/export;
- configured workflow selection, destination selection, and an exact pre-write preview;
- fixed parent paths such as `01 Shoots`, configurable job naming, complete folder trees, and a
  configured media landing folder;
- safe copying of an actual team-supplied Premiere template under a derived name, with no invented
  project files and no overwrite;
- copy/never-move, no operator-media deletion, never-overwrite, staged writes, read-back checksum,
  MHL, sidecar, marker-and-lock-proven restart cleanup, explicit partial-result behavior, and
  deterministic destination-disconnect/reconnect coverage;
- truthful per-destination receipt wording when MHL is written, disabled, or cannot be written,
  with output problems separated from media-verification language;
- off-main, cancellable, fail-closed card discovery with an explicit scanning state, immediate
  cancellation when the operator changes sources, visible blocking errors for unreadable source
  subtrees, stale-result protection, and direct selection of camera package folders such as RED
  `.RDC` clips;
- a reusable example configuration and customization/QA runbook; and
- focused tests for defaults, package round trips, token rendering, validation, structure creation,
  template creation/collision behavior, and plan-to-output.

This is standalone Labs software. It opens directly into Ingest. The app binary contains no Drives
registry, Drive Passport, Media Nexus, Relay, account, telemetry, update checker, or network client,
and its sandbox has no network entitlement. Those are separate product surfaces.

## Prior release candidate

Version 0.2.1 was compiled as a universal app, Developer ID signed, notarized, and stapled in August
2026. Its local DMG has SHA-256
`dc035849d9786d2caf7d9f961cd25f18f3facb58f8c3e41aa83205623e9df523`.

That DMG predates VLP-415. It does not contain the current configuration-driven workflow and must
not be presented as the finished lead magnet. Nothing is publicly downloadable yet.

## Verification and release boundary

The 0.3.0 source passes 49 of 49 native tests and static analysis. Its build 17 universal
Intel/Apple Silicon review DMG has SHA-256
`3eff7ad0242e72e2d7ca44fd833d6fb50c89b0faef6ef8298dc170905b64ab44`, passes strict local
signature verification, is sandboxed, and has no network entitlement. A visible read-only ExFAT
card exercise completed the brief, exact job preview, folder creation, hidden camera-metadata
handling, copy, read-back verification, ASC MHL, ingest record, timestamp preservation, relaunch,
bookmark restoration, and no-rewrite rerun. Independent SHA-256 checks matched all intended source
and destination copies and confirmed the source volume was unchanged. The exact build 7 package
also proved that configured carry-over answers survive a full quit/relaunch, while card/reel stays
blank and the automatic date remains current. Build 8 additionally completed and verified a
12.88 GB packaged transfer, froze the visible brief during the run, preserved the original brief in
the receipt, and reran with zero media bytes rewritten. See [AUDIT.md](AUDIT.md) for the durable
receipt. Build 9 also proved through the packaged UI that disabling MHL produces a truthful
disabled-manifest receipt and no new manifest, then restored the normal preference. Build 10
proved that importing different naming rules while a card is already selected immediately rebuilds
the live plan and rename preview, without requiring a source reselection or relaunch. Its full-card
no-rewrite run and subsequent quit/relaunch also restored the configured carry-over brief.
Build 11 removes singular-count rough edges from the source preview, progress copy, problem notice,
and final result summary, with explicit one-file and multi-file summary coverage. Build 13 moves
source discovery and sorting off the UI actor, shows a truthful scanning state, and cancels obsolete
work before opening the source picker. The packaged app stayed interactive on a synthetic
500,000-file card, cancelled that scan immediately when `Change` was chosen, and published only the
two-file replacement plan without a partial or stale result. Build 14 adds a deterministic
destination-disconnect/reconnect exercise: destination loss during a staged copy leaves no partial
final file or changed source, and a retry after reconnection completes, verifies, and removes
staging debris. It also makes camera-package sources directly selectable and destination removal
persistent and accessibility-labeled. Build 16 rejects an existing file occupying any configured
folder path before changing the destination, refuses to publish a copy when its source changes
during transfer, supports jobs directly under the selected destination when no fixed parent folder
is configured, and makes form-field organization controls persistently accessible.
Build 17 responds to the independent review by preserving foreign and active staging contents,
cleaning only marker-bound abandoned app sessions, blocking ingest when any source subtree cannot
be read, and correcting the release pipeline so the byte-final DMG is submitted before stapling.

The exact DMG also passed checksum, install, strict-signature, architecture, entitlement, version,
and launch checks on `VL-Mini-02` running macOS 26.6.2. Separately, the exact transfer engine copied,
read back, and verified a disposable 64 MB file on the attached 2 TB physical external
`SANDBOX-VOLUME-01`, preserved its modification time and source bytes, then reran with zero bytes
rewritten. The clean Mac had no physical card or external drive, and its existing GUI session was
locked against remote input, so a clean-Mac UI offload, physical camera card, and live cable
disconnect/reconnect remain `not_run`. VLP-415 still requires a fresh independent exact-commit
review of build 17 before acceptance. Developer ID signing, notarization, public download hosting,
and the website funnel are authorized release work. Physical-card qualification, campaign
activation, production/client deployment, and a real team's configuration remain separate or
explicitly deferred work.

## Checks still required before public release

- Independently review the exact build 17 implementation commit.
- Sign, notarize, staple, and independently verify the byte-final package.
- Publish and verify the exact public positioning, version, download, checksum, and install path.

Physical camera-card, live cable disconnect/reconnect, and real-team configuration exercises are
deferred; the release receipt must continue to describe them as `not_run`.

See [spec.md](spec.md) for product authority and [CONFIGURATION.md](CONFIGURATION.md) for the
customization contract.
