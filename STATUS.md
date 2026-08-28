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
- the existing copy/never-move, never-delete, never-overwrite, read-back checksum, MHL, sidecar,
  partial-result, and cancellation behavior;
- a reusable example configuration and customization/QA runbook; and
- focused tests for defaults, package round trips, token rendering, validation, structure creation,
  template creation/collision behavior, and plan-to-output.

This is standalone Labs software. It opens directly into Ingest, and the active journey has no
Media Nexus/Relay dependency or compiled Relay client.

## Prior release candidate

Version 0.2.1 was compiled as a universal app, Developer ID signed, notarized, and stapled in August
2026. Its local DMG has SHA-256
`dc035849d9786d2caf7d9f961cd25f18f3facb58f8c3e41aa83205623e9df523`.

That DMG predates VLP-415. It does not contain the current configuration-driven workflow and must
not be presented as the finished lead magnet. Nothing is publicly downloadable yet.

## Verification and release boundary

The 0.3.0 source passes a clean native test run (19 passed, 2 opt-in real-drive tests skipped) and an
unsigned Release configuration build. VLP-415 still requires independent diff review and hands-on
product exercise before it is a release candidate. Developer ID signing, notarization, public
download hosting, website funnel, campaign activation, production/client deployment, and a real
team's configuration are separate approval-boundary work.

## Hands-on checks still required before public release

- Exercise source-card selection, required form values, configured job preview, destination
  selection, folder creation, project-template behavior, copy, verification, MHL, and sidecar in the
  real app UI.
- Run synthetic card cases for name clashes, unplug/interruption, read-only destinations, multiple
  destinations, and re-ingest/resume.
- Verify the checksum implementation against an independent tool.
- Decide whether Drive Passports and the resident Drives view belong in the first public release.
- Review the exact public positioning, version, and download experience.

See [spec.md](spec.md) for product authority and [CONFIGURATION.md](CONFIGURATION.md) for the
customization contract.
