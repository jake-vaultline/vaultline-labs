# Vaultline Labs Drive Inspector — app

**v0.1.0 — signed, notarized, and shipping.** Feature-complete: filesystem walk, media
probe (codecs/resolutions/cameras), duplicate detection, and HTML/PDF/CSV report
export, all in one no-network, sandboxed app. See `../STATUS.md` for what's still open
before wider testing.

## Build

```bash
brew install xcodegen          # one time
cd app
xcodegen generate
open VaultlineLabsDriveInspector.xcodeproj
```

Then set your team in **Signing & Capabilities** (or fill `DEVELOPMENT_TEAM` in
`project.yml` and regenerate) and hit Run.

**Manual fallback if you'd rather not use XcodeGen:** File → New → Project → macOS App
(SwiftUI), then delete the generated `ContentView.swift` and `App.swift`, drag in
`Sources/`, point the target at `Resources/Info.plist` and
`Resources/VaultlineLabsDriveInspector.entitlements`, and enable Hardened Runtime and
App Sandbox.

## What's implemented

- Drag-and-drop a drive or folder, or pick one via the open panel
- Background filesystem walk with cancellation
- Live-updating results, republished on a 150ms throttle rather than per file
- Type breakdown (video / photo / audio / project / sidecar / other) by count and bytes
- Top formats by extension
- True recursive folder sizes, top 25
- Top 100 largest files, tracked with a bounded top-N so a 500k-file drive doesn't get
  sorted in full
- Media-only date range
- Empty folder detection
- Project file and project bundle detection
- Volume name, capacity, free space

## What's still open

- **Real-drive edge-case testing** — FCP library with media inside, camera card
  structure, permission-denied subfolders, a network volume, a Mac that's never run
  the app. See `../STATUS.md`
- **Hosting** — the DMG isn't published anywhere yet

## Architecture notes

**Three files matter.**

`ScanEngine.swift` — `Walker.walk()` returns an `AsyncStream<ScanSnapshot>`. The walk
runs in a detached task and yields a fresh immutable snapshot every 150ms. SwiftUI just
assigns it. This is why a 500k-file scan doesn't melt the UI: the view updates ~7 times
a second no matter how fast files are being counted.

`Accumulator` keeps mutable scan state separately from the published snapshot, so the
expensive derived work (sorting largest files and folders) only runs when publishing,
not per file.

Folder sizes are computed by crediting every ancestor directory up to the scan root as
each file is seen — true recursive sizes in a single pass, no second traversal.

## The permission model — read before changing anything

The app is **sandboxed**, with `files.user-selected.read-only` and **no network
entitlement**.

This combination is deliberate and load-bearing:

- Sandboxing is what makes the missing network entitlement *enforced by the OS* rather
  than merely promised. A non-sandboxed app can open sockets whatever its entitlements
  say
- User-selected read-only means the user granting access by dragging or picking **is**
  the permission model. No Full Disk Access prompt, no TCC onboarding flow, nothing to
  explain on first run
- Sandboxing does not require the Mac App Store — Developer ID distribution is fine

Consequence: the app can only ever see what the user hands it. That's the correct
behavior for this tool and it makes the privacy claim checkable by anyone.

## Testing it honestly

Test on a real messy drive, not a clean folder. Specifically check:

- A drive with an FCP library containing media (does the count look right?)
- A camera card structure — `PRIVATE/M4ROOT`, `XDROOT`, `DCIM`
- A folder with symlinks (should be skipped, not followed into a loop)
- A network volume (slow — does the UI stay responsive and does Stop actually stop?)
- A drive with permission-denied subfolders (the error handler skips and continues)
