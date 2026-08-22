# Optional Cloud Drive Passport Contract

**Status: VLP-207 QR-FIRST PROTOTYPE. NOT RELEASED.**

Vaultline Ingest remains fully functional without an account or network connection. Connecting a
Drive Passport workspace is optional and does not change local scan, ingest, checksum verification,
manifest, sidecar, or drive-history behavior.

When connected, the native client may upload only the bounded snapshot envelope implemented in
`DrivePassportClient`:

- observation time and scan mode;
- overall file and capacity aggregates;
- at most 64 top-level collection names, each at most 120 characters, with aggregate bytes;
- a bounded change summary; and
- manifest/idempotency fingerprints.

It must never upload media, file contents, filenames, hidden entries, local paths, ingest
destinations, client form answers, or raw physical identifiers. Failed uploads stay in the local
metadata-only outbox and never block the local product.

The permanent QR and NFC URL is owned by the separate Drive Passport service. Ingest supplies a
single-use five-minute code after a local snapshot; an authenticated operator enters that code at
the tag URL. The physical tag is never rewritten when drive facts or assignments change.

The complete architecture, Media Nexus boundary, physical qualification gate, and launch criteria
are recorded in the Labs experiment's `architecture-v1.md`.
