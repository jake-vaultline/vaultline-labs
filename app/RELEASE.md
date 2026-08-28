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

**Entitlement contract.** The build fails if the sandbox is off, if either
network entitlement appears, if any broad filesystem entitlement appears, or if
user-selected read-write is missing.

**Network surface.** The build fails if any app source creates common URLSession,
Network.framework, Core Foundation stream, web-view, or shell-process clients. The
public standalone utility has no account, telemetry, update check, Relay, Media
Nexus, Drive Passport, or other network client.

Neither guard should ever be bypassed to get a build out.

## Installing the standalone utility

```
curl -fsSL https://vaultline.io/ingest/install.sh | bash
```

That downloads the notarized build, verifies the checksum, copies the standalone app to
Applications, and opens it. A team's portable JSON configuration is imported from
Settings → Team Setup; it contains workflow rules and no credentials or server connection.

---

## Still to do before this ships

- [x] Compiles with Xcode 26.6 (2026-08-09)
- [x] `XXHash64.swift` verified against reference vectors and streamed test cases;
      see `../AUDIT.md`
- [x] Configuration-driven structure creation and safe real project-template copying
- [x] Safe restart after interruption via verified existing-file resume
- [x] Standalone journey has no Media Nexus/Relay dependency
- [ ] Physical-card qualification — see `../STATUS.md`
