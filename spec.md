# Vaultline Labs Ingest — product specification

**Status: VLP-415 review candidate. Standalone 0.3.0 passes native tests, a universal Release build,
synthetic-card edge cases, and hands-on UI qualification. Independent exact-diff review and public
release gates remain. The notarized 0.2.1 DMG predates this work and is not this version.**

## Product

Vaultline Labs Ingest is a free, excellent, standalone macOS card-ingest and offload utility for
in-house media teams. It works without an account, Media Nexus, or Relay. Vaultline configures each
team's workflow for free within a bounded portable configuration; every team uses the same app
binary and release pipeline.

It is intentionally separate from the branded Media Nexus Relay workstation app. Relay is managed
client software with shared server authority. Labs Ingest is a local utility and lead magnet.

## Operator journey

1. Choose or drop a source card/folder.
2. Fill the team's brief ingest form. The useful default asks for shoot date, shooter, location,
   subject/project, camera, job number, card/reel, and notes. Teams can change every field.
3. Choose a configured workflow and a destination drive/folder.
4. Preview the exact derived job name, fixed parent folder, complete folder tree, media landing
   folder, and optional project-template output.
5. Create the job. Date tokens are automatic; the operator supplies only meaningful values.
6. Start ingest. The app copies to every destination, reads every copy back, verifies checksums,
   writes an ASC MHL manifest and a human-readable ingest record, and reports exceptions first.

## Team configuration

The versioned JSON package configures:

- form fields, stable tokens, labels, types, choices, required/sticky behavior, and defaults;
- workflow names and descriptions;
- job-name patterns such as `{date:yyMMdd}_{project}` and `{jobNumber}_{project}`;
- optional configured destination-root suggestions and optional fixed relative parent folders such
  as `01 Shoots` (an empty parent puts the job directly under the chosen destination);
- the complete job folder tree and exact media landing folder;
- optional edit/project folders;
- an optional real client-supplied Premiere project template and derived output name; and
- checksum, manifest, sidecar, and file-renaming preferences. Verification, copy-only behavior,
  and visible collision reporting are mandatory safety rules, not configurable switches.

Configuration import is transactional: unsupported schemas, duplicate workflow IDs, empty
workflows, unsafe/traversing paths, inconsistent media/project folder references, missing required
tokens, missing project templates, and project-file collisions fail visibly.

The app never fabricates a `.prproj`. With a validated real template, it copies the template without
overwrite. Without one, it creates the configured project folder and explains that no project file
was created.

## Safety rules

These rules outrank every feature:

1. Copy, never move. The source card remains untouched.
2. Never delete.
3. Never overwrite. Matching content counts as already verified; different content is a conflict.
4. Read every destination copy back and match its checksum before reporting verification.
5. Preserve card subfolder structure beneath the configured media landing folder.
6. Write manifests only for verified files.
7. Expose partial completion, cancellation, conflicts, and failures in operator language.
8. Reject configuration paths that could escape the selected destination.
9. Stage every new copy under an app-owned hidden path, verify it there, then atomically publish it
   at the intended media path. Cancellation never leaves a partial final file.
10. On restart, remove only abandoned app-owned staging data; a rerun hashes and skips complete
    matching files, so interruption recovery needs no fragile transfer database.
11. Block destinations inside the source, overlapping destination roots, and rename plans that
    would collapse multiple source files onto one destination path.

## Customization boundary

Free customization includes the package dimensions listed above and a bounded synthetic acceptance
exercise. It does not include source forks, new features, bespoke integrations, shared multi-Mac
state, Media Nexus/Relay connection, signing, publication, production deployment, or indefinite
workflow consulting.

The example package and delivery procedure live in [CONFIGURATION.md](CONFIGURATION.md).

## Release boundary

VLP-415 may implement, test, build, and prepare a reviewable source commit. Developer ID signing,
notarization, public download hosting, website/lead-capture deployment, campaign activation, and
real-client configuration are separate protected steps.

## Product boundary decision

The first public binary is ingest-only. Drive Inspector/inventory, Drive Passport, Relay, Media
Nexus, accounts, telemetry, update checks, and all other network behavior are separate products or
future product decisions. The exact public version and release date follow hands-on product review.
