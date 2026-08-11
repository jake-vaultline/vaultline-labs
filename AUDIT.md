# Vaultline Ingest — pre-compile audit

2026-08-07. What was checked without a compiler, and what it found.

---

## 1. xxHash64 — VERIFIED CORRECT

The highest-risk file in the project, and the one everything else trusts. Now the
best-tested.

`XXHash64.swift` was ported line-for-line to Python — including its 32-byte buffering,
the stripe loop, the tail handling and the avalanche — and run against the reference
`xxhash` implementation:

| | |
|---|---|
| Lengths tested | every length 0–200, plus 1 KB, 4 KB, 64 KB, 1 MB, 1 MB + 13 |
| Modes | one-shot **and** streamed in chunks of 1, 7, 32, 33, 4096, 100003 bytes — the odd-boundary path the offload engine actually uses |
| Canonical vectors | `""` → `ef46db3751d8e999` · `"a"` → `d24ec4f1a98c6e5b` · `"abc"` → `44bc2cf5ad770999` — all match |
| **Mismatches** | **0** |

The algorithm and buffering are right. What's left to confirm on a Mac is only that the
Swift transcription compiles and behaves the same — one `shasum`-style spot check against
`xxhsum` on a real file is enough.

---

## 2. Bugs found and fixed

None of these would have been caught by reading the code casually; two of them would have
produced an app that *runs* and quietly does the wrong thing.

| Bug | Why it mattered |
|---|---|
| **`AppState` missing `import SwiftUI`** | Uses `Binding` for form fields. Straight compile error |
| **Nested ObservableObjects never propagated** | SwiftUI doesn't observe an `ObservableObject` held inside another one. Views watching `AppState` would have seen *nothing* when `configStore`, `volumes`, `nexus` or the network log published — the drive list would sit stale, settings changes wouldn't appear to take, and the request log would stay empty even while requests were happening. Fixed by forwarding each child's `objectWillChange` in `AppState.init` |
| **`NSWorkspace` observer tokens discarded** | Block-based observers can be released when their token isn't retained. The app would have silently stopped noticing drives being plugged in — the worst kind of bug, because it looks like nothing is wrong |
| **`h ^ x &* y` without parentheses** | `&*` binds tighter than `^` in Swift, so the expression didn't mean what it read as. Only a fingerprint, but a wrong fingerprint means false "nothing changed" reports |
| **Unsorted digest fold** | Fixed alongside — folder digests now fold over sorted hashes, so two identical drives can't be reported as different because of enumeration order |
| **Redundant `objectWillChange.send()`** | Left over from before `upsert` handled publishing |

---

## 3. Checked and believed sound

- Every state-changing path in `OffloadEngine` — no move, no delete, no overwrite exists
  in the file at all
- `CollisionPolicy` has no `.overwrite` case
- Security scopes held across all passes, released in every exit path including cancel
- `release.sh` guards: sandbox on, no `network.server`, no broad filesystem entitlement,
  and no `URLSession` outside `NexusClient.swift` (verified — nothing else creates one)
- MHL manifest lists verified files only
- Sidecar never overwrites an existing record; it suffixes instead
- Sequence numbers come from a stable sort, so re-running a card doesn't renumber

---

## 4. What only a Mac can settle

- Does it compile. Expect some errors — 4,400 lines, never built
- SwiftUI layout: nothing here has been rendered
- TCC / sandbox behaviour on a real external volume
- `NSWorkspace` mount notifications with a real card
- Whether `xxhsum` agrees with the Swift build on a real file

---

## 5. Honest status of "send a client a command"

**Not yet public.** The command, installer, checksum gate, pairing hand-off, download
page, and signed/notarized/stapled 0.2.1 DMG all exist. The installer is pinned to the
final artifact SHA-256. What does not exist is the DMG and download surface at the
public URL.

Release checklist:

1. ~~`xcodegen generate` → build in Xcode → fix compile errors~~
2. ~~Fill in Team ID (`ExportOptions.plist`, `project.yml`)~~
3. ~~Produce a signed, notarized, stapled DMG and pin its SHA-256 in `install.sh`~~
4. Upload the DMG, `install.sh`, and `index.html`

After step 4 the command works, for anyone.
