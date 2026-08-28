# Vaultline Labs Ingest configuration

Vaultline Labs Ingest is one free standalone app. A team's ingest form, naming, destination layout,
folder tree, media landing folder, and optional real Premiere template are data in a portable JSON
configuration—not a source fork and not a Media Nexus connection.

## Bounded free customization

Vaultline configures:

- the form fields, labels, required/sticky behavior, choices, defaults, and stable tokens;
- one or more workflow presets;
- job-name templates such as `{date:yyMMdd}_{project}` or `{jobNumber}_{project}`;
- a fixed parent path under the destination selected by the operator, such as `01 Shoots`;
- the complete relative folder tree and the exact media landing folder;
- an optional destination-root suggestion;
- an optional client-supplied `.prproj` template and its derived output name; and
- checksum, manifest, sidecar, and rename preferences. Verification, copy-only behavior, and
  visible collision reporting are mandatory safety rules, not configurable switches.

Free customization does not include new features, integrations, shared state, Media Nexus/Relay,
bespoke source forks, signing, deployment, or ongoing workflow engineering.

## Configuration workflow

1. Copy `configuration/example-team.json` and change only the team's values.
2. Keep `schemaVersion` at `1`.
3. Give every form value used in a template a stable alphanumeric `token`.
4. Use relative paths only. Absolute paths, `..`, `.`, empty paths, and colon-bearing components fail
   validation. `destinationRoot`, when present, is the sole optional absolute path.
5. Ensure `mediaFolder` and `projectFolder` exactly name folders in `folders`.
6. If the team supplies a Premiere template, put its base64-encoded bytes in
   `projectTemplateBase64` and set `projectNameTemplate` to a `.prproj` name. This keeps the package
   portable and sandbox-safe. `projectTemplatePath` is available for local development only; never
   configure both. Without a template, the app creates the project folder and deliberately creates
   no fake project file.
7. Import the JSON from Settings → Team Setup. The app validates the complete package before changing
   its active configuration.
8. Export it again and diff the round trip before delivery.

## Acceptance exercise

Use synthetic files and a disposable destination. Fill the ingest form, choose the source, create a
configured job, and inspect the complete preview before starting. Confirm the expected parent/job
name, folder tree, media landing folder, optional template copy, read-back verification, ASC MHL, and
plain-text ingest record. Repeat the same card to prove matching files are not rewritten. Put a
different file at one destination path to prove it is reported and left untouched. Interrupt a copy
and rerun. Finally confirm the source card is byte-for-byte unchanged.

Signing, notarization, publication, website delivery, and any real-client configuration remain
separate approval and release steps.
