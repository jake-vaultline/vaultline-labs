# Local Archive Assessment — VLP-1809

Metadata-only Mac CLI candidate. Run with existing Python 3.9+; no install,
server, Media Nexus account or dependency download. This subtree is independent
of Inspector's scan/hash/probe engine and does not modify its app targets.

The approved November 6 contract separates a read-only scanner from an explicit
output writer. **`assess` creates no output directory, report file, or private
checkpoint.** It emits a bounded aggregate JSON document to a terminal or pipe.

```sh
python3 -B assessment/Sources/assessment.py assess --root /explicit/selected/root
# PRIVATE_EXPORT_PARENT already exists, is owned by you, and is mode 0700.
# The exporter deliberately writes this new directory; it is a separate operation.
python3 -B assessment/Sources/assessment.py assess --root /explicit/selected/root |
  python3 -B assessment/Sources/assessment.py export --output "$PRIVATE_EXPORT_PARENT/fresh-output"
python3 -B -m unittest discover -s assessment/Tests -v
```

Check the scanner's own exit status when using a pipeline (for example with your
shell's `pipefail`): an exporter can successfully save an explicitly partial or
cancelled report. A pipeline's last exit status alone does not prove a full scan.

`assess --output` and `resume --checkpoint` are retired and fail closed without
opening the old checkpoint. Restart an interrupted assessment with the same
explicit roots and policy: it fully rescans, replaces prior aggregates, and does
not double-count interrupted work. There is no persistent inventory or watcher.

## Read-only scanner boundary

Scanner stdout **and stderr** must be terminals, pipes or sockets. Regular files
and devices are refused before parsing or source traversal, including parser
errors and progress diagnostics. The scanner therefore does not write report
bytes through an already-open source-file descriptor. A shell can create or
truncate a redirection target *before Python starts*; the scanner cannot undo a
caller's shell effects. Use a pipe, not `> source-file` or `2> source-file`.
A pipe consumer's deliberate writes are outside the scanner process boundary.

All selected-source I/O is descriptor-relative directory enumeration/stat, with
nofollow directory handles and identity checks. Regular source files are never
opened. No source file-body reads, report/checkpoint writes, hashing, project
parsing, probes, subprocesses, fetches, uploads or portal writes occur in assess.
The tests spy on actual filesystem opens and retain all eight prior late-export
relocation scenarios at the scanner's new stdout-publication seam.

Root path components must be real directories, not symlinks or aliases. On macOS
use canonical `/private/var/...` temporary paths. Duplicate/same-filesystem nested
roots collapse; explicitly selected nested device identities remain separate.
No implicit mount discovery or unselected mount descent occurs. Hidden regular
files are included; three known system trees are excluded. `--exclude` accepts
at most 100 root-relative patterns; only the pattern count is public, never the
patterns or source paths. Unavailable roots produce partial coverage where safe;
symlink selections are rejected.

Defaults: one worker, 100 metadata entries/second, 30 minutes, 1 million regular
paths, depth 64. Explicit `--metadata-rate` may rise to 10,000 for local fixtures;
`--max-files`, `--max-depth`, and `--max-seconds` lower their respective limits.
There is no percentage/ETA. SIGINT/SIGTERM yields a cancelled aggregate after the
current metadata call returns. Kernel blocking may outlive cancellation; no
real-NAS abort or OS-enforced no-network promise is made. OS metadata providers
may perform their own I/O; no content or hydration is requested.

Scanner exit codes: 0 complete for observed policy, 2 partial/limited, 130 cancelled,
1 unsafe startup/stream. Unknown unseen counts/bytes remain null. No automatic
retry, reconnection, authentication or privileged access occurs.

## Explicit exporter boundary

`export` reads at most 16 MiB of aggregate JSON from stdin and validates the closed
schema, bounded fields, known vocabularies and normalized aliases. Unknown or
private checkpoint fields, duplicate keys, nonfinite numbers and malformed input
are refused before destination creation. It creates only `assessment.json`,
`assessment.md`, and `suggestions.json`; it never emits private recovery state.
The parent must already be owned by the current user with mode 0700. The output
must be new, component paths must not be symlinks, the new directory is 0700, and
new files are 0600 with exclusive creation. Preexisting outputs are preserved.
Detected output replacement or relocation refuses subsequent publication.

**The exporter intentionally writes its caller-authorized destination.** It is
not part of the scanner's zero-write guarantee. A process with the same user's
rights can move a same-filesystem destination between checks and an actual file
open. Path/descriptor checks do not provide kernel confinement against that
attacker. Choose a protected destination outside the assessed roots and do not
run the exporter in a namespace controlled by another writer. An OS-enforced
no-source-write exporter would require a separately confined/protected namespace;
this candidate does not claim one. Historical race failures are preserved at
commit `c92c2bb1`; they have not been relabeled passing exporter confinement.

Counts and normalized patterns can still be sensitive. Review before sharing.
Aggregate input is not an authenticated attestation; validation does not prove
that an assessment was genuinely performed or that its counts are truthful.

## Interpretation and suggestions

Mac local identity uses native statfs MNT_LOCAL and nonzero device/inode. Remote
or missing identities stay unknown and cannot prove deduplication. Logical bytes
count regular path entries; distinct logical bytes and allocated `st_blocks*512`
bytes are separate. Clones/snapshots/shared extents prevent interpreting allocation
as unique physical occupation. Capacity covers identified visible local mounted
filesystems, not physical RAID/NAS topology. Placeholders remain unassessed.

Extensions are allowlisted; private suffixes become `other`. Names become bounded
A/D/S class shapes; rare shapes are suppressed. Layouts are child-directory-count
classes, not semantic templates or approved workflows. Project suffixes/packages
are artifacts, not distinct productions or verified dependencies. Date ranges
are filesystem modification dates, never capture dates. No codec inference,
backup assurance or safe-to-erase claim is made.

The pure `suggestions(report, surface, human)` mapper targets only the full
onboarding surface. It proposes verified field keys with evidence/as-of/coverage
and uncertainty. Partial totals are lower bounds; contact, access, preferences,
sample and success-criteria fields stay blank. Existing or unsaved human values
produce alternates; no human text is exported or overwritten. `save` and `submit`
are always false. It never authenticates, persists, or imports a Portal draft.

Reuse attribution: separator-aware boundaries follow Core Relay's
`read-only-scanner.js`; metadata/capacity concepts follow Inspector's
`ScanEngine.swift`. Neither runtime is imported.

## Open / undecided

No signed distribution, browser importer, Windows guarantee, real NAS
qualification, or OS-confined exporter is included. The optional 100k benchmark
uses disposable synthetic metadata and measures its named host only; it is not
client throughput evidence. Exact-source independent review remains required.
