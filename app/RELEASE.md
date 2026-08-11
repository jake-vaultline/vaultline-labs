# Releasing Vaultline Ingest

```bash
cd ~/Documents/vaultline-labs/tools/vaultline-ingest/app
xcodegen generate
./release.sh
```

One-time setup — Team ID, Developer ID Application certificate, and the
`vaultline-notary` keychain profile — is identical to Drive Inspector and documented in
`../../vaultline-inspector/app/RELEASE.md`. If you've already shipped Inspector, there's
nothing new to set up here beyond filling in `teamID` in `ExportOptions.plist` and
`DEVELOPMENT_TEAM` in `project.yml`.

Current machine state (2026-08-09): the Team ID and working Developer ID key are
configured, and the archive signs successfully. The `vaultline-notary` keychain
profile is absent, so the pipeline intentionally stops at Apple's submission step.
Do not publish the resulting DMG until a rerun reaches staple and Gatekeeper success.
`--no-notarize` produces an internal release candidate and deliberately does not
instruct the operator to update the public installer or upload the DMG.

---

## After every build

`release.sh` prints the DMG's SHA-256. Put it in `../download/install.sh`:

```bash
VERSION="0.2.1"
SHA256="<the printed hash>"
```

The installer refuses to open a DMG that doesn't match. Skipping this means a client
installing over a hostile network has no way to know they got your build.

Then upload `build/VaultlineIngest-<version>.dmg` and `install.sh` alongside
`index.html`, and update the version on the page.

---

## The two guards in this pipeline

Ingest's release checks are the inverse of Inspector's, and they exist because this app
has a much wider blast radius.

**Entitlement contract.** The build fails if the sandbox is off, if
`network.server` appears (this app is a client, never a listener), if any broad
filesystem entitlement appears, or if user-selected read-write is missing.

**Network surface.** The build fails if any file other than the two audited service
clients (`NexusClient.swift` and `DrivePassportClient.swift`) creates a `URLSession`.
Both write to the same Settings → Network log. The moment another code path can make a
request, that panel stops being evidence and becomes decoration.

Neither guard should ever be bypassed to get a build out.

### Proving physical identity under the release sandbox

Run the diagnostic against a mounted external drive:

```bash
Diagnostics/verify-identity-sandbox.sh /Volumes/NAME
```

It compiles the production `VolumeIdentity` collector into a temporary background
app, signs it with the same hardened-runtime and sandbox entitlements as Ingest,
reports only whether each signal is present, and removes the temporary app. It never
prints serials or other identifier values and never reads drive contents.

---

## Sending it to a client

```
curl -fsSL https://vaultline.io/ingest/install.sh | \
  NEXUS_URL="https://nexus.theirstudio.local" NEXUS_CODE="ABC-123" bash
```

That downloads the notarized build, verifies the checksum, copies the app to
Applications, and opens the pairing prompt pre-filled with their Nexus address. They
confirm it and they're reporting.

Pairing is still a human confirmation on purpose — a URL that silently connected a
workstation to a server would be a fine piece of malware.

---

## Still to do before this ships

- [x] Compiles with Xcode 26.6 (2026-08-09)
- [x] `XXHash64.swift` verified against reference vectors and streamed test cases;
      see `../AUDIT.md`
- [ ] Structure creation from the learned convention (the wizard produces the template;
      nothing builds trees from it yet)
- [ ] Resume after interruption
- [ ] The Nexus endpoints (`/api/relay/pair`, `/config`, `/ingest`, `/volumes`) don't
      exist on the server side yet
- [ ] Real-card testing — see `../STATUS.md`
