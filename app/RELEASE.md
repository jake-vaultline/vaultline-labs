# Releasing Vaultline Labs Drive Inspector

How a `.swift` file becomes something a stranger can double-click. Everything here runs
on Jake's Mac — none of it can be done from a Linux session.

---

## The short version

```bash
cd ~/Documents/vaultline-labs/tools/vaultline-inspector/app
xcodegen generate          # only if project.yml changed
./release.sh
```

Out comes `build/VaultlineLabsDriveInspector-0.1.0.dmg`, signed, notarized, stapled,
and openable by anyone on macOS 13+.

---

## One-time setup (do this once, ever)

### 1. Team ID

Find your 10-character Team ID in the Apple Developer portal (Membership), then put it
in **two** places:

- `ExportOptions.plist` → `teamID`
- `project.yml` → `DEVELOPMENT_TEAM`, then re-run `xcodegen generate`

### 2. Developer ID certificate

Xcode → Settings → Accounts → your Apple ID → Manage Certificates → **+** →
**Developer ID Application**.

This is the one that matters. Not "Apple Development" (works only on your machines) and
not "Mac App Distribution" (App Store only). Picking the wrong one produces a build that
runs perfectly on your Mac and is blocked on everyone else's — the single most common
way this goes wrong, and it fails silently until someone else tries it.

### 3. App-specific password for notarization

Apple ID → Sign-In and Security → App-Specific Passwords → generate one.
Then store it in the keychain so `release.sh` can use it unattended:

```bash
xcrun notarytool store-credentials "vaultline-notary" \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

Do this once. The profile name `vaultline-notary` is what `release.sh` expects.

### 4. Optional niceties

```bash
brew install xcodegen     # regenerates the Xcode project from project.yml
brew install xcbeautify   # readable xcodebuild output; the script works without it
```

---

## What `release.sh` actually does

| Step | Why it's there |
|---|---|
| Archive | Release configuration, optimized |
| Export with `developer-id` | Signs with the Developer ID Application certificate |
| **Entitlement guard** | **Hard-fails the release if a network entitlement appears, or if the sandbox is off.** See below |
| Signature verify | Catches a broken or partial signature before Apple does |
| DMG | With an `/Applications` symlink, so install is one drag |
| Notarize | Uploads to Apple, waits for the verdict |
| Staple app, repackage, staple DMG | See "why twice" below |
| `stapler validate` + `spctl` | Confirms a clean machine will accept it |

### The entitlement guard

The strongest claim this app makes is *"it cannot reach the network — check the
entitlements yourself."* That claim is worth more than any feature, and it is exactly
one careless commit away from being false.

So the release refuses to build if:

- any `com.apple.security.network.*` entitlement is present, **or**
- App Sandbox is off — because without the sandbox, a missing network entitlement is
  unenforced and the claim is meaningless

Do not "temporarily" bypass this to test something. Ship a different target if you need
networking; this one never gets it.

### Why staple twice

Stapling only the DMG leaves the *app* without a ticket. Someone who drags the app to
Applications and first launches it offline gets a Gatekeeper failure that's very hard to
reproduce and looks like a broken app. So: staple the app, rebuild the DMG around the
stapled app, staple that too.

---

## What the user experiences

Because the app is notarized and stapled, there is **no right-click-Open dance and no
scary warning.** Download, open the DMG, drag to Applications, launch. That's it.

On first scan, macOS shows the standard file-picker; whatever the user drags in or
selects is the only thing the app can ever read. No Full Disk Access prompt, no System
Settings trip.

If a tester reports "unidentified developer" or "damaged and can't be opened," the build
was not properly signed or not stapled. Re-run `release.sh` and check the notarization
output rather than telling them to right-click.

---

## Shipping a new version

1. Bump `MARKETING_VERSION` in `project.yml`, `xcodegen generate`
2. `./release.sh`
3. Upload the DMG
4. Update the version, date and file size on the download page
   (`../download/index.html`)

No auto-update exists by design — the app has no network access, so it cannot check for
one. Users return to the download page. Revisit only if the update burden becomes real.

---

## Not done yet

Distribution is solved. The product is not. Before this goes public:

- [ ] **Report export** — the button exists and is disabled. This is the whole
      marketing surface (`../report/report-spec.md`); shipping without it wastes the
      launch
- [ ] **Pass 2** — codecs, resolutions, frame rates, duration, cameras. Without it the
      app shows roughly a third of what the report template promises
- [ ] First-run test on a Mac that has never seen the app
- [ ] Test on a real messy drive: FCP library with media inside, camera card structure,
      permission-denied folders, a network volume
- [ ] Decide the "no verified second copy" question (`../report/report-spec.md` §5)
- [ ] Somewhere to host the DMG
