# Vaultline Labs Ingest — status

## Current VLP-415 source (0.3.0)

The app is being productized as a free standalone configurable ingest/offload utility. The current
task branch includes:

- a useful default ingest form for date, shooter, location, subject/project, camera, job number,
  card/reel, and notes;
- stable form tokens and automatic date rendering;
- a versioned portable team-configuration package with transactional validation and import/export;
- configured workflow selection, destination selection, and an exact pre-write preview;
- fixed parent paths such as `01 Shoots`, configurable job naming, complete folder trees, and a
  configured media landing folder;
- safe copying of an actual team-supplied Premiere template under a derived name, with no invented
  project files and no overwrite;
- copy/never-move, never-delete, never-overwrite, staged writes, read-back checksum, MHL, sidecar,
  safe restart, interruption cleanup, and explicit partial-result behavior;
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

The 0.3.0 source passes 27 of 27 native tests. Its universal Intel/Apple Silicon Release review
build passes strict local signature verification, is sandboxed, and has no network entitlement. A
visible synthetic-card exercise completed the brief, exact job preview, folder creation, copy,
read-back verification, ASC MHL, ingest record, no-rewrite rerun, and visible conflict journeys.
Independent SHA-256 checks matched the source and clean destination copies; the generated MHL files
validated against the official ASC reference XSD. See [AUDIT.md](AUDIT.md) for the durable receipt.

VLP-415 still requires independent exact-diff review before acceptance. Clean-Mac and physical-card
qualification, Developer ID signing, notarization, public download hosting, website funnel,
campaign activation, production/client deployment, and a real team's configuration are separate
release-boundary work.

## Checks still required before public release

- Qualify the accepted review build on a clean Mac with a physical camera card and external
  destination, including a real disconnect/reconnect.
- Independently review the exact implementation commit.
- Review the exact public positioning, version, and download experience.

See [spec.md](spec.md) for product authority and [CONFIGURATION.md](CONFIGURATION.md) for the
customization contract.
