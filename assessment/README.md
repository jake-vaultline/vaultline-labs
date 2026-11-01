# Local Archive Assessment — VLP-1809

Metadata-only Mac CLI candidate. Run with existing Python 3.9+; no install,
server, Media Nexus account or dependency download. This subtree is independent
of Inspector's existing scan/hash/probe engine and does not modify its targets.

```sh
python3 -B assessment/Sources/assessment.py assess --root /explicit/selected/root --output /outside/root/fresh-output
python3 -B assessment/Sources/assessment.py resume --checkpoint /previous/output/private-checkpoint.json --output /new/fresh-output
python3 -B -m unittest discover -s assessment/Tests -v
```

The output parent must exist; the output itself must be new. Root/output path
components must be real directories, not symlinks or aliases. On macOS temporary
paths often include `/var` aliases: supply canonical `/private/var/...` paths.
Selected duplicate/same-filesystem nested roots collapse; explicitly selected
nested device identities stay separate because parent traversal excludes them.
There is no implicit mount discovery or mount
descent. Hidden regular files are included; three known virtual/system trees are
excluded. `--exclude` accepts at most 100 root-relative glob patterns; these raw
patterns remain private in recovery state, not public policy. A root selection
failure is recorded as partial where safe; symlink selections are rejected.

Defaults: sequential traversal (one worker), 100 metadata entries/second,
30-minute segment, 1-million regular paths, depth 64. Explicit `--metadata-rate`
may rise to 10,000 for local fixtures; `--max-files`, `--max-depth` and
`--max-seconds` may lower the limits. Observed progress has no percentage/ETA.
SIGINT/SIGTERM produces cancelled exports and private recovery state after the
current metadata call returns. Kernel blocking may outlive cancellation; this
candidate makes no real-NAS abort or OS-enforced no-network promise. OS metadata
providers may perform their own I/O. No content/hydration is requested.

Exit codes: 0 complete for observed policy, 2 partial/limited, 130 cancelled,
1 unsafe startup/save/recovery. Source changes or permission exceptions create
partial coverage; unknown unseen counts/bytes stay null. No automatic retries,
reconnection, authentication or privileged access.

`assessment.json`, `assessment.md`, `suggestions.json` are redacted aggregate
exports. Review before sharing: even counts/patterns can disclose information.
`private-checkpoint.json` contains root paths, identities and exclusions; directory
mode 0700 / file mode 0600. Never share it. Resume validates schema/policy/root
identities, fully rescans every root, and replaces all previous contributions
in a fresh output directory. No cached counts are reused, no interrupted unit is
double-counted. Changed roots require a new assessment. This trades speed for
transparent reconciliation; default limits apply independently to each rescan.

All source I/O is descriptor-relative directory enumeration/stat, with nofollow
directory handles, identity checks and pinned output handles. Regular source
files are never opened. The only regular input read is explicitly selected,
private, size-bounded recovery state. Source writes, hashing, media/project
parsing, probes, subprocesses, remote fetches, uploads and portal writes are absent.

Mac local filesystem identity uses native statfs MNT_LOCAL and nonzero device/inode; remote or
missing identities remain unknown and are not used to prove deduplication.
Logical bytes count regular path entries. Reliable distinct-object logical bytes
and allocated bytes (`st_blocks * 512`, excluding separate file metadata accounting)
are distinct metrics. Shared extents/clones/snapshots prevent interpreting allocation
as unique physical occupation. Capacity is distinct identified local filesystem
capacity, not physical storage: remote unidentified mount capacities are deliberately
omitted. The source selected mount observation is never a complete disk/NAS topology.
Placeholder counts depend on platform metadata; all contents remain unassessed.

Extension vocabulary is allowlisted; unknown/private suffixes map to `other`.
Names become A/D/S token-class shapes; rare shapes are suppressed. Folder layout
currently means a repeated child-directory-count class, not a semantic folder
template or approved workflow. Histograms are bounded; no median/p90 or codec
claims. Project suffixes/packages mean artifacts, not distinct productions or
verified linked media. Date range is filesystem modification dates only.

The pure mapper `suggestions(report, surface, human)` accepts only the full
onboarding surface, aggregate v1 and known status. It proposes verified field
keys and a template summary, with evidence/as-of/coverage/certainty. No connection
protocol is invented. Pilot root aliases require confirmation. Partial totals
are lower-bound observations; human contacts/preferences/access/sample/success
criteria stay blank. Existing/unsaved human values produce alternates; no human
text is copied into exports, silently overwritten or appended. `save` and `submit`
are always false. The mapper does not authenticate, persist or import a draft.

Reuse attribution: separator-aware root boundaries follow Core Relay
`read-only-scanner.js`; metadata/capacity concepts follow Inspector `ScanEngine.swift`.
No existing engine module is imported and no shared files are edited.

Open limits: no signed client distribution, browser importer, media sample,
semantic folder templates, Windows guarantee or real NAS qualification. The
100k synthetic benchmark records named host, RSS/time/output/cancellation only;
it is not client-archive throughput evidence. Exact-commit independent review is
required before implementation acceptance.

Recovery state is owner-private local input, not an authenticated tamper-proof
record. Unknown settings and discrepancies against its public policy are rejected;
no command-line policy override is allowed on resume. Deliberate edits to both
policy records cannot be authenticated without a signing/secret boundary, which
is outside this slice; use a new assessment when changing policy.

R1/R2 repair: capture original selected-source directory identities before output
creation. Check pinned output parent/directory ancestry against those identities
after mkdir/open and before each export; an original source renamed into the
output path cannot become the expected output identity. Recovery metadata is
checked before opening; its descriptor is opened O_NONBLOCK|O_NOFOLLOW, then
type/owner/mode/identity are rechecked before any read. This rejects local FIFO
replacement without waiting for a writer. Chunked bounded checkpoint reads check
the cancellation flag and reject mid-read mutations. Valid checkpoints still
resume by full rescan; no checkpoint is treated as an authenticated client record.
