# Vaultline Ingest — status

**Compiled. Drive Passport MVP integrated. Developer ID signed, notarized, and stapled.**
2026-08-09.

Release candidate: `app/build/VaultlineIngest-0.2.1.dmg` (universal, hardened,
signed, notarized, and stapled). SHA-256:
`dc035849d9786d2caf7d9f961cd25f18f3facb58f8c3e41aa83205623e9df523`.
Apple accepted submission `6b4f66a3-dbb8-4048-839b-a331cbce59fd`; stapler
validation and Gatekeeper assessment of the mounted app both pass. The DMG is
not yet published to the public download channel.

Native verification: 20 XCTest cases executed, 18 passed, and the two opt-in
real-drive cases skipped in the normal suite. The real-drive identity/transport
case has also passed separately against a mounted SSD and the local service.

Design of record: `spec.md`. Release process: `app/RELEASE.md`.

---

## The client-facing answer

```
curl -fsSL https://vaultline.io/ingest/install.sh | \
  NEXUS_URL="https://nexus.theirstudio.local" NEXUS_CODE="ABC-123" bash
```

Downloads the notarized DMG, verifies its SHA-256 before opening it, copies the app to
Applications, opens the pairing prompt pre-filled. Without the environment variables it's
the same command for a free, unpaired install — one artifact, one command, both audiences.

---

## What the app does

**Two halves**, switched in the title bar.

### Drives — the standing view

Every drive this Mac has seen, mounted or not. Capacity, last seen, sighting count, and
**what changed since the previous plug-in**. Useful on a day nobody ingests anything,
which is what makes it worth leaving installed.

- Mount/unmount detected via `NSWorkspace`
- Scanning is **explicit per drive**, never automatic — silently reading every disk
  someone inserts is a surprising thing for a tool to do unasked
- Keyed on **volume UUID**, so three different cards at `/Volumes/Untitled` stay separate
- Snapshot is a **folder-level fingerprint**, not a file index — a per-file record of a
  500k-file drive would make the registry bigger than the media it describes
- Top-level totals include files at every descendant depth; canonical path handling
  prevents macOS path aliases such as `/var` → `/private/var` from corrupting grouping
- States its own limit in the UI: copies of this app can't see each other's drives
- Can connect to the separate hosted Drive Passport service, upload a bounded
  quick snapshot, and create a five-minute code that pairs a physical tag
- Stores failed snapshot uploads in a metadata-only SQLite outbox, retries with
  exponential backoff, and shows pending sync counts in the UI
- Retains a rejected snapshot in that outbox instead of deleting the only queued
  copy; permanent server errors remain visible during both immediate upload and
  background flush, with regression tests for both paths
- Keeps service credentials in the macOS Keychain with iCloud synchronization
  explicitly disabled; connection fails visibly if secure storage is unavailable.
  The current Developer ID archive uses the traditional macOS keychain, so it does
  not yet claim that credentials cannot migrate with a restored login keychain
- Pauses possible/reformatted drive matches before upload and requires an explicit
  same-physical-drive or create-new decision; conflicting strong signals stay blocked
- Contains a best-effort hardware serial/media UUID/vendor/model/topology collector
  and never promotes the legacy name+capacity fallback to a strong UUID. A reusable
  hardened-runtime probe signed with Ingest's exact sandbox entitlements found every
  field on both mounted USB SSDs without reading contents or adding an entitlement
- Refreshes identity evidence for previously enrolled drives whenever the Passport
  service is reachable. It explicitly binds the new evidence to the cached drive ID,
  blocks cache conflicts, and preserves offline snapshot queuing when transport is down

### Ingest — the pipeline

New Job → shoot details → destinations → copy → verify → manifest → sidecar.

| Step | |
|---|---|
| **New Job** | Creates the folder tree before the card goes in. Defaults to separating **Shoot** from **Edit**, which most teams don't do. Auto-adds the shoot folder as a destination |
| **Naming** | Learned from existing work by the wizard; renames are previewed before anything is written |
| **Shoot details** | User-configured fields. Sticky ones carry to the next card |
| **Copy** | One source read fanned to N destinations, hashed in flight |
| **Verify** | Every copy read back off disk and compared |
| **Manifest** | ASC MHL, verified files only |
| **Sidecar** | Plain-text record: the form answers plus files verified, algorithm, destinations, clashes, per-file hashes |
| **Results** | Per-file list, problems first |

---

## Files

| | |
|---|---|
| **Engine** | `OffloadEngine`, `XXHash64`, `Checksums`, `MHLWriter`, `NameTemplate` |
| **Drives** | `VolumeMonitor` (registry, mount events, snapshot + diff), `VolumeIdentity` (best-effort physical signals) |
| **Naming** | `NamingAnalyzer` (infer + consistency score), `SetupWizard` |
| **Jobs** | `StructureBuilder`, `JobSheet` |
| **Form** | `IngestForm` (model + sidecar), `FormViews` (fill + configure) |
| **Relay client** | `NexusClient`, `NetworkLog`, `Keychain` |
| **Config** | `Config`, `Bookmarks` |
| **UI** | `Theme` (design system), `App`, `AppState`, `IngestView`, `DrivesView`, `SettingsView` |
| **Distribution** | `release.sh`, `RELEASE.md`, `ExportOptions.plist`, `download/index.html`, `download/install.sh`, `Diagnostics/verify-identity-sandbox.sh` |

---

## Decisions worth not re-litigating

**Two apps, not one.** Merging with Drive Inspector would cost Inspector its no-network
entitlement — its strongest, least copyable claim.

**The network promise is proved by a log, and the build enforces it.** `release.sh` fails
if any file other than `NexusClient.swift` creates a `URLSession`.

**No delete, no move, no overwrite — as absent code paths, not defaults.**

**Resume falls out of the collision rule.** A destination file is hashed, not overwritten:
identical means done, different means clash. No state file to go stale.

**Verified means read back and matched**, after `synchronize()` — verifying against the
page cache proves nothing about the disk.

**Scanning is opt-in per drive.** See above.

**Pairing needs a human click.** The install command pre-fills; it never connects silently.

**Dark only.** Every tool this sits beside is dark. `Theme.swift` is the single source —
nothing elsewhere hardcodes a colour.

**Amber for attention, never red.** Nothing this app does is destructive; a red alarm
would overstate every notice and train people to ignore the next one.

**Plain text sidecar, not a database row.** It outlives the app.

**The real logo, not a text wordmark.** From `branding/source-copies`, at @1x/2x/3x.

**Not doing: generating Premiere/Resolve projects.** Undocumented, version-fragile, and a
corrupt project on a shoot day costs more trust than the feature could earn.

---

## Still to do

| | Who |
|---|---|
| ~~Compile, fix errors~~ — Debug build succeeds with Xcode 26.6 | Done 2026-08-09 |
| **Verify `XXHash64` against `xxhsum`** — everything trusts it | Jake |
| Card testing: clash, cable pulled mid-offload, read-only destination, two destinations, MHL read elsewhere | Jake |
| ~~Developer ID sign a universal 0.2.1 release candidate~~ | Done 2026-08-09 |
| ~~Add and unit-test the Drive Passport SQLite outbox~~ | Done 2026-08-09 |
| ~~Integrate-test native offline snapshot → durable queue → restored transport → drain~~ | Done 2026-08-09 |
| ~~Refresh physical identifiers for cached Passport drives without breaking offline fallback~~ | Done 2026-08-09 |
| ~~Add and test explicit possible-match/reformat identity review~~ | Done 2026-08-09 |
| ~~Add an opt-in real-drive Passport integration harness~~ — normal test runs skip it safely | Done 2026-08-09 |
| ~~Run real-drive identity → native client → local service → pairing → redaction proof without recursively scanning contents~~ | Done 2026-08-09 |
| Run the full content-scanning harness unlocked against a responsive real mounted drive — two locked-screen attempts stalled during volume enumeration before any API request; a later bounded read-only `find` also blocked until terminated | Jake |
| ~~Verify physical identity under Ingest's signed sandbox entitlements~~ — all fields present on both attached SSDs; no added entitlement | Done 2026-08-09 |
| ~~Notarize and staple the universal 0.2.1 DMG; record the final SHA~~ | Done 2026-08-09 |
| Public download hosting | Jake |
| **Media Nexus endpoints** — `/api/relay/pair`, `/config`, `/ingest`, `/volumes` don't exist server-side | Claude, in the sandbox repo |
| Multi-card queue | Claude |
| Handoff summary as HTML/PDF matching Inspector's report | Claude |
| Vector logo for print/NFC labels | Jake |

## Open / undecided

- Notarized 0.2.1 release timing relative to the Drive Inspector launch
- Whether public Drive Passport auth uses the current private-host boundary or
  a dedicated identity provider
- Repeat the locally proven offline → reconnect → drain path against the production
  host once its native API is reachable
- Provision the data-protection Keychain entitlement (or add server-side hardware
  binding) before making a device-only credential migration claim

**Overlap to settle:** both apps now scan drives. Inspector is a one-shot deep *report*;
Ingest is a continuous *registry*. That line is thin and is the most likely thing to
confuse someone who downloads both — resolve before a joint launch.
