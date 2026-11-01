"""VLP-1809: metadata only; no regular source-file opens or network libraries.

Boundary principle adapted from Relay read-only-scanner.js inside(root,candidate),
and Inspector ScanEngine's selected-root metadata/capacity model. Neither runtime
is imported: its hash/probe/store/transport sequence is intentionally excluded.
"""
from __future__ import annotations

import argparse
import ctypes
from collections import Counter
from datetime import datetime, timezone
import errno
import fnmatch
import json
import os
from pathlib import Path
import signal
import stat
import sys
import time
import uuid

VERSION = "archive-assessment-v1"
SURFACE = "full-archive-onboarding"
KNOWN = set("mov mp4 mxf avi wav mp3 aiff flac jpg jpeg png tif tiff exr dng r3d braw prproj drp aep aepx xml fcpxml aaf edl txt pdf csv json".split())
PROJECT = set("prproj drp aep aepx".split())
VIDEO = set("mov mp4 mxf avi r3d braw".split())
AUDIO = set("wav mp3 aiff flac".split())
PHOTO = set("jpg jpeg png tif tiff exr dng".split())
PACKAGES = {"fcpbundle", "fcpxmld", "dra"}
SYSTEM = {".Spotlight-V100", ".Trashes", ".fseventsd"}
LIMIT = 128
FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
OUTPUTS = {}


def now():
    return datetime.now(timezone.utc).isoformat()


def inside(root, candidate):
    return os.path.commonpath([root, candidate]) == root


def identity(s):
    return [s.st_dev, s.st_ino] if s.st_ino > 0 and s.st_dev > 0 else None


def local_mount(fd):
    """Darwin mount.h statfs64 prefix; no path/device names exported.

    statvfs flags are POSIX flags, not Darwin MNT_LOCAL. Use the actual metadata
    ABI for this distinction, and fall back to unknown if unavailable.
    """
    if sys.platform != "darwin":
        return False
    class Prefix(ctypes.Structure):
        _fields_ = [("bsize", ctypes.c_uint32), ("iosize", ctypes.c_int32),
                    ("blocks", ctypes.c_uint64), ("bfree", ctypes.c_uint64),
                    ("bavail", ctypes.c_uint64), ("files", ctypes.c_uint64),
                    ("ffree", ctypes.c_uint64), ("fsid", ctypes.c_int32 * 2),
                    ("owner", ctypes.c_uint32), ("type", ctypes.c_uint32),
                    ("flags", ctypes.c_uint32)]
    libc = ctypes.CDLL(None, use_errno=True)
    native = getattr(libc, "fstatfs$INODE64", None)
    if native is None and __import__("platform").machine() == "arm64":
        native = getattr(libc, "fstatfs", None)
    if native is None:
        return False
    native.argtypes = [ctypes.c_int, ctypes.c_void_p]
    native.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if native(fd, buffer):
        return False
    return bool(Prefix.from_buffer(buffer).flags & 0x1000)


def open_dir(path):
    """Open every path component relative to a pinned parent, without symlinks."""
    path = os.path.abspath(path)
    fd = os.open("/", FLAGS)
    try:
        for part in Path(path).parts[1:]:
            child = os.open(part, FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def roots_normalized(paths):
    checked = []
    for path in paths:
        path = os.path.abspath(path)
        try:
            fd = open_dir(path)
        except OSError as exc:
            if exc.errno not in {errno.EACCES, errno.EPERM, errno.ENOENT, errno.ESTALE, errno.EIO}:
                raise
            checked.append((path, None))
            continue
        try:
            checked.append((path, identity(os.fstat(fd))))
        finally:
            os.close(fd)
    kept = []
    for path, ident in sorted(set((p, tuple(i) if i else None) for p, i in checked)):
        # Parent traversal refuses device transitions. An explicitly selected
        # nested filesystem must therefore remain its own traversal root.
        if not any(inside(p, path) and (not ident or not i or ident[0] == i[0]) for p, i in kept):
            kept.append((path, list(ident) if ident else None))
    return kept


def policy(**kwargs):
    result = dict(max_files=1000000, max_depth=64, max_seconds=1800.0,
                  metadata_rate=100.0, excludes=[])
    if set(kwargs) - set(result):
        raise ValueError("unknown policy setting")
    result.update(kwargs)
    if not 1 <= result["max_files"] <= 1000000 or not 1 <= result["max_depth"] <= 64:
        raise ValueError("file/depth limit out of range")
    if not 0 < result["max_seconds"] <= 1800 or not 0 < result["metadata_rate"] <= 10000:
        raise ValueError("time/rate limit out of range")
    if len(result["excludes"]) > 100:
        raise ValueError("too many exclusions")
    return result


def public_policy(p):
    return {**{k: v for k, v in p.items() if k != "excludes"},
            "exclusion_patterns": len(p["excludes"]), "hidden_files": "included",
            "system_trees": "excluded", "links": "never-follow",
            "packages": "contents-counted-once", "mounts": "no-descent",
            "workers": 1, "rate_unit": "enumerated_entries_per_second", "metadata_provider": "may perform its own metadata IO"}


def bucket(counter, key, amount=1):
    if key not in counter and len(counter) >= LIMIT:
        key = "overflow"
    counter[key] += amount


def shape(name):
    # Only classes, no literal tokens, extensions, date digits or rare names.
    parts = []
    last = None
    for c in name:
        k = "D" if c.isdigit() else "A" if c.isalpha() else "S"
        if k != last:
            parts.append(k)
            last = k
        if len(parts) >= 8:
            break
    return "".join(parts) or "empty"


def blank():
    return dict(path_entries=0, logical_bytes=0, directories=0, project_artifacts=0,
                project_packages=0, distinct_objects=0, distinct_logical_bytes=0,
                allocated_bytes=0, allocated_objects=0, identity_unknown=0,
                placeholders=0, size_sum=0, minimum_mtime=None, maximum_mtime=None,
                extensions=Counter(), extension_bytes=Counter(), categories=Counter(), category_bytes=Counter(), size_bins=Counter(), depth_bins=Counter(),
                token_shapes=Counter(), layouts=Counter(), errors=Counter(), skipped=Counter())


def run(roots, p, cancelled=lambda: False, progress=lambda x: None, hook=lambda *a: None):
    start = time.monotonic()
    report = dict(schema_version=VERSION, run_id=str(uuid.uuid4()), started_at=now(),
                  status="complete", policy=public_policy(p), roots=[], mounts=[], limitations=[
                      "Observation over time, not an atomic snapshot.",
                      "Unknown unseen bytes and files; partial totals are lower bounds.",
                      "Visible mounted capacity is not physical RAID/NAS topology.",
                      "No content, codecs, linked dependencies or backup assurance assessed.",
                      "OS/provider metadata IO may occur; no hydration requested.",
                      "Kernel filesystem calls may outlive cancellation; no NAS abort guarantee.",
                      "Resume reconciles by fully rescanning, replacing prior aggregates."])
    agg = blank()
    seen = set()
    mounts = {}
    last_progress = start
    next_op = start
    stopped = False

    def gate():
        nonlocal next_op, stopped, last_progress
        if cancelled():
            stopped = True
            report["status"] = "cancelled"
            return False
        if time.monotonic() - start >= p["max_seconds"] or agg["path_entries"] >= p["max_files"]:
            stopped = True
            report["status"] = "partial"
            return False
        # Cooperative rate limiting, with cancellation checks at <=50ms intervals.
        delay = next_op - time.monotonic()
        while delay > 0:
            time.sleep(min(delay, .05))
            if cancelled():
                stopped = True
                report["status"] = "cancelled"
                return False
            delay = next_op - time.monotonic()
        if time.monotonic() - start >= p["max_seconds"]:
            stopped = True
            report["status"] = "partial"
            return False
        next_op = time.monotonic() + 1 / p["metadata_rate"]
        if time.monotonic() - last_progress >= .25:
            progress({"files_observed": agg["path_entries"], "logical_bytes": agg["logical_bytes"],
                      "elapsed_seconds": round(time.monotonic() - start, 2)})
            last_progress = time.monotonic()
        return True

    def error(exc):
        key = {errno.EACCES: "permission", errno.EPERM: "permission", errno.ENOENT: "vanished",
               errno.ESTALE: "disconnected", errno.EIO: "io", errno.ELOOP: "replacement"}.get(getattr(exc, "errno", None), "metadata_failure")
        agg["errors"][key] += 1
        if report["status"] == "complete":
            report["status"] = "partial"

    def walk(fd, root_dev, reliable, depth, relative):
        before = os.fstat(fd)
        child_shapes = Counter()
        hook("enumerate", relative)
        with os.scandir(fd) as entries:
            for entry in entries:
                if not gate():
                    break
                rel = relative + "/" + entry.name
                if entry.name in SYSTEM or any(fnmatch.fnmatchcase(rel.lstrip("/"), x) for x in p["excludes"]):
                    agg["skipped"]["excluded"] += 1
                    continue
                try:
                    hook("stat", rel)
                    s = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
                    if stat.S_ISLNK(s.st_mode):
                        agg["skipped"]["link"] += 1
                        continue
                    if stat.S_ISDIR(s.st_mode):
                        if s.st_dev != root_dev:
                            agg["skipped"]["mount"] += 1
                            report["status"] = "partial"
                            continue
                        agg["directories"] += 1
                        bucket(agg["depth_bins"], str(depth + 1))
                        bucket(child_shapes, shape(entry.name))
                        if entry.name.lower().rsplit(".", 1)[-1] in PACKAGES:
                            agg["project_packages"] += 1
                            agg["project_artifacts"] += 1
                        if depth >= p["max_depth"]:
                            agg["skipped"]["depth_limit"] += 1
                            report["status"] = "partial"
                            continue
                        hook("before_open_dir", rel)
                        child = os.open(entry.name, FLAGS, dir_fd=fd)
                        try:
                            if identity(os.fstat(child)) != identity(s):
                                raise OSError(errno.ESTALE, "changed directory")
                            walk(child, root_dev, reliable, depth + 1, rel)
                            if identity(os.stat(entry.name, dir_fd=fd, follow_symlinks=False)) != identity(s):
                                raise OSError(errno.ESTALE, "changed directory")
                        finally:
                            os.close(child)
                    elif stat.S_ISREG(s.st_mode):
                        hook("after_stat", rel)
                        current = os.stat(entry.name, dir_fd=fd, follow_symlinks=False)
                        if (identity(current), current.st_size, current.st_mtime_ns, current.st_mode) != (identity(s), s.st_size, s.st_mtime_ns, s.st_mode):
                            raise OSError(errno.ESTALE, "file changed")
                        agg["path_entries"] += 1
                        agg["logical_bytes"] += s.st_size
                        raw_ext = entry.name.lower().rsplit(".", 1)[-1] if "." in entry.name else "none"
                        ext = raw_ext if raw_ext in KNOWN or raw_ext == "none" else "other"
                        bucket(agg["extensions"], ext)
                        bucket(agg["extension_bytes"], ext, s.st_size)
                        category = "probable_video" if ext in VIDEO else "probable_audio" if ext in AUDIO else "probable_photo" if ext in PHOTO else "project_artifact" if ext in PROJECT else "other"
                        bucket(agg["categories"], category)
                        bucket(agg["category_bytes"], category, s.st_size)
                        if raw_ext in PROJECT:
                            agg["project_artifacts"] += 1
                        size_bin = "zero" if not s.st_size else "lt1KiB" if s.st_size < 1024 else "lt1MiB" if s.st_size < 1048576 else "lt1GiB" if s.st_size < 1073741824 else "ge1GiB"
                        bucket(agg["size_bins"], size_bin)
                        bucket(agg["token_shapes"], shape(entry.name))
                        try:
                            date = datetime.fromtimestamp(s.st_mtime, timezone.utc).isoformat()
                            agg["minimum_mtime"] = min(agg["minimum_mtime"] or date, date)
                            agg["maximum_mtime"] = max(agg["maximum_mtime"] or date, date)
                        except (ValueError, OverflowError, OSError):
                            pass
                        ident = identity(s) if reliable else None
                        if not ident:
                            agg["identity_unknown"] += 1
                        elif tuple(ident) not in seen:
                            seen.add(tuple(ident))
                            agg["distinct_objects"] += 1
                            agg["distinct_logical_bytes"] += s.st_size
                            if hasattr(s, "st_blocks"):
                                agg["allocated_objects"] += 1
                                agg["allocated_bytes"] += s.st_blocks * 512
                        if getattr(s, "st_flags", 0) & getattr(stat, "SF_DATALESS", 0) or hook("placeholder", rel):
                            agg["placeholders"] += 1
                    else:
                        agg["skipped"]["special"] += 1
                except OSError as exc:
                    error(exc)
        after = os.fstat(fd)
        if (before.st_mtime_ns, before.st_ctime_ns) != (after.st_mtime_ns, after.st_ctime_ns):
            error(OSError(errno.ESTALE, "directory changed during observation"))
        # Structural classes only, bounded child-count bins; no literal examples.
        layout = str(min(sum(child_shapes.values()), 100)) + ("+" if sum(child_shapes.values()) > 100 else "")
        bucket(agg["layouts"], layout)

    for index, (path, expected) in enumerate(roots):
        item = {"alias": "Root " + str(index + 1), "status": "complete"}
        report["roots"].append(item)
        errors_before = sum(agg["errors"].values())
        skips_before = agg["skipped"]["mount"] + agg["skipped"]["depth_limit"]
        if stopped:
            item["status"] = "unobserved"
            continue
        fd = None
        try:
            fd = open_dir(path)
            s = os.fstat(fd)
            if expected and identity(s) != expected:
                raise OSError(errno.ESTALE, "root replaced")
            hook("root", path)
            if os.path.basename(path).lower().rsplit(".", 1)[-1] in PACKAGES:
                agg["project_packages"] += 1
                agg["project_artifacts"] += 1
            v = None
            try:
                hook("capacity", path)
                v = os.fstatvfs(fd)
            except OSError:
                agg["errors"]["capacity_unknown"] += 1
                if report["status"] == "complete":
                    report["status"] = "partial"
            # Mac ST_LOCAL distinguishes locally backed mounts. Unknown remote IDs
            # are not used to prove object or capacity deduplication.
            reliable = local_mount(fd)
            if hook("identity", path) is False:
                reliable = False
            if reliable and s.st_dev not in mounts:
                mounts[s.st_dev] = "Mount " + str(len(mounts) + 1)
                report["mounts"].append({"alias": "Mount " + str(len(mounts)),
                    "total_bytes": v.f_blocks * v.f_frsize if v else None,
                    "available_bytes": v.f_bavail * v.f_frsize if v else None, "as_of": now()})
                item["mount_alias"] = "Mount " + str(len(mounts))
            elif reliable:
                item["mount_alias"] = mounts[s.st_dev]
            else:
                item["mount_alias"] = None
            walk(fd, s.st_dev, reliable, 0, "")
            check = open_dir(path)
            try:
                if identity(os.fstat(check)) != identity(s):
                    raise OSError(errno.ESTALE, "root replaced")
            finally:
                os.close(check)
        except OSError as exc:
            error(exc)
        finally:
            if fd is not None:
                os.close(fd)
        if sum(agg["errors"].values()) > errors_before or agg["skipped"]["mount"] + agg["skipped"]["depth_limit"] > skips_before or stopped:
            item["status"] = "partial"
    if agg["identity_unknown"]:
        agg["distinct_objects"] = None
        agg["distinct_logical_bytes"] = None
    agg["mean_file_bytes"] = agg["logical_bytes"] / agg["path_entries"] if agg["path_entries"] else None
    agg["allocated_bytes"] = agg["allocated_bytes"] if agg["allocated_objects"] else None
    del agg["size_sum"]
    # Suppress rare patterns; denominator is explicit and includes suppressed entries.
    for key in ("token_shapes", "layouts"):
        values = agg[key]
        agg[key] = dict(observed=sum(values.values()), suppressed=sum(n for n in values.values() if n < 3),
                        patterns={k: n for k, n in sorted(values.items()) if n >= 3 and k != "overflow"},
                        overflow=values.get("overflow", 0))
    report["aggregates"] = agg
    report["finished_at"] = now()
    report["coverage"] = dict(unseen_files=None, unseen_bytes=None,
                              observed_regular_entries=agg["path_entries"],
                              errors=sum(agg["errors"].values()), exclusions=sum(agg["skipped"].values()),
                              content_reads=0, codec_sample=None, identities_unknown=agg["identity_unknown"])
    return report


def suggestions(r, surface=SURFACE, human=None):
    if surface != SURFACE or r.get("schema_version") != VERSION or r.get("status") not in {"complete", "partial", "cancelled"}:
        raise ValueError("unsupported assessment or intake surface")
    a = r["aggregates"]
    if not isinstance(a.get("path_entries"), int) or a["path_entries"] < 0:
        raise ValueError("invalid aggregate")
    if set(a["extensions"]) - KNOWN - {"other", "none"}:
        raise ValueError("invalid extension vocabulary")
    if any(type(n) is not int or n < 0 for n in a["extensions"].values()):
        raise ValueError("invalid extension counts")
    for key in ("logical_bytes", "directories", "project_artifacts"):
        if type(a.get(key)) is not int or a[key] < 0:
            raise ValueError("invalid aggregate counts")
    for key in ("errors", "exclusions"):
        if type(r["coverage"].get(key)) is not int or r["coverage"][key] < 0:
            raise ValueError("invalid coverage")
    if len(r["roots"]) > 100 or len(r["mounts"]) > 100:
        raise ValueError("unbounded roots")
    for i, mount in enumerate(r["mounts"]):
        if mount.get("alias") != "Mount " + str(i + 1):
            raise ValueError("invalid mount alias")
        for key in ("total_bytes", "available_bytes"):
            if mount.get(key) is not None and (type(mount[key]) is not int or mount[key] < 0):
                raise ValueError("invalid capacity")
    for date in (r["finished_at"], a["minimum_mtime"], a["maximum_mtime"]):
        if date is not None:
            datetime.fromisoformat(date)
    uuid.UUID(r["run_id"])
    if any(x.get("alias") != "Root " + str(i + 1) for i, x in enumerate(r["roots"])):
        raise ValueError("invalid root aliases")
    for k in ("token_shapes", "layouts"):
        if any(not isinstance(key, str) or len(key) > 9 or not set(key) <= (set("ADS") if k == "token_shapes" else set("0123456789+")) for key in a[k]["patterns"]):
            raise ValueError("invalid normalized patterns")
        if any(type(n) is not int or n < 0 for n in a[k]["patterns"].values()):
            raise ValueError("invalid pattern count")
        if any(type(a[k][v]) is not int or a[k][v] < 0 for v in ("observed", "suppressed", "overflow")):
            raise ValueError("invalid pattern coverage")
    caveat = " Observed lower bound; incomplete coverage." if r["status"] != "complete" else " Observed selected roots only."
    values = {
        "storageDescription": f"{len(r['roots'])} selected roots; {len(r['mounts'])} identified local mounted filesystems. Physical topology unknown.",
        "networkNotes": f"Status: {r['status']}; metadata exceptions {r['coverage']['errors']}; exclusions {r['coverage']['exclusions']}. Unseen content unknown.",
        "scopeFolders": ", ".join(x["alias"] for x in r["roots"]) + "; proposed scan scope, confirm pilot scope.",
        "approximateSize": f"{a['logical_bytes']} logical bytes across {a['path_entries']} regular path entries." + caveat,
        "projectCount": f"{a['project_artifacts']} observed project artifacts; unique production count unknown." + caveat,
        "fileTypes": "; ".join(f"{k}: {v}" for k, v in sorted(a["extensions"].items())) + ". Codecs not assessed.",
        "additionalNotes": f"Metadata assessment: {a['path_entries']} regular entries, {a['directories']} directories, {a['logical_bytes']} logical bytes. Status {r['status']}. Project artifacts {a['project_artifacts']}; linked media and codecs not assessed. Permission/error count {r['coverage']['errors']}; unseen content unknown." + caveat,
    }
    if r["mounts"]:
        values["totalCapacity"] = "; ".join(f"{m['alias']}: capacity {m['total_bytes'] if m['total_bytes'] is not None else 'unknown'} bytes, available {m['available_bytes'] if m['available_bytes'] is not None else 'unknown'} bytes" for m in r["mounts"]) + ". No physical-storage sum."
    if a["minimum_mtime"]:
        values["dateRange"] = a["minimum_mtime"] + " to " + a["maximum_mtime"] + "; filesystem modification dates, not capture dates."
    for field, key in (("folderExample", "layouts"), ("namingConvention", "token_shapes")):
        if a[key]["patterns"]:
            values[field] = json.dumps(a[key], sort_keys=True) + "; normalized observation only, not approved workflow."
    human = human or {}
    result = []
    for key, value in values.items():
        # No human text is copied into shareable output, including unsaved edits.
        conflict = bool(human.get(key, "").strip())
        result.append(dict(field=key, value=value, evidence="aggregates/coverage", as_of=r["finished_at"],
            coverage=r["status"], certainty="inferred_pattern" if key in {"folderExample", "namingConvention"} else "observed",
            action="alternate_preserve_human" if conflict else "suggest_empty_field", requires_confirmation=True))
    return {"schema_version": VERSION, "surface": SURFACE, "run_id": r["run_id"],
            "suggestions": result, "save": False, "submit": False}


def markdown(r):
    a = r["aggregates"]
    return "\n".join(["# Archive Assessment", "", f"Status: **{r['status']}**", f"As of: {r['finished_at']}",
        "", f"Observed selected roots: {len(r['roots'])}", f"Regular path entries: {a['path_entries']}",
        f"Logical bytes: {a['logical_bytes']}", f"Distinct objects: {a['distinct_objects']}",
        f"Allocated bytes: {a['allocated_bytes']} ({a['allocated_objects']} observed distinct objects)",
        f"Directories: {a['directories']}; project artifacts: {a['project_artifacts']}",
        "", "## Distributions", "", "```json", json.dumps({k: a[k] for k in ('extensions', 'extension_bytes', 'categories', 'category_bytes', 'size_bins', 'depth_bins', 'layouts', 'token_shapes')}, indent=2, sort_keys=True), "```",
        "", "## Visible mounted storage", "", "```json", json.dumps(r['mounts'], indent=2), "```",
        "", "## Coverage and policy", "", "```json", json.dumps({"roots": r['roots'], "coverage": r['coverage'], "errors": a['errors'], "skipped": a['skipped'], "policy": r['policy']}, indent=2), "```",
        "", "## Limits", "", *["- " + x for x in r['limitations']],
        "", "Counts and normalized patterns can still be sensitive. Review before voluntarily sharing.",
        "Keep private-checkpoint.json local. No upload or form submission occurred.", ""])


def outside_source_ancestry(fd, source_ids):
    """Check pinned directory ancestry, independent of renamed path strings."""
    current = os.dup(fd)
    try:
        for _ in range(256):
            ident = identity(os.fstat(current))
            if ident is None or tuple(ident) in source_ids:
                raise ValueError("output identity/ancestry overlaps source")
            parent = os.open("..", FLAGS, dir_fd=current)
            parent_ident = identity(os.fstat(parent))
            os.close(current)
            current = parent
            if parent_ident == ident:
                return
        raise ValueError("unbounded output ancestry")
    finally:
        os.close(current)


def output_dir(path, roots):
    path = os.path.abspath(path)
    if any(inside(root, path) or inside(path, root) for root, _ in roots):
        raise ValueError("output overlaps assessed roots")
    parent, name = os.path.split(path)
    fd = open_dir(parent)
    try:
        # Capture selected source identities BEFORE mkdir/open. An attacker
        # substituting the source at the creation/open seam cannot redefine the
        # expected output identity to that source, as the old code did.
        source_ids = set()
        for root, expected in roots:
            if expected is not None:
                source_ids.add(tuple(expected))
            try:
                source = open_dir(root)
            except OSError as exc:
                if exc.errno in {errno.ENOENT, errno.EACCES, errno.EPERM, errno.ESTALE, errno.EIO}:
                    continue
                raise
            try:
                observed = identity(os.fstat(source))
                if observed is None or expected is not None and observed != expected:
                    raise ValueError("source identity changed before output creation")
                source_ids.add(tuple(observed))
            finally:
                os.close(source)
        outside_source_ancestry(fd, source_ids)
        os.mkdir(name, 0o700, dir_fd=fd)
        child = os.open(name, FLAGS, dir_fd=fd)
        try:
            outside_source_ancestry(child, source_ids)
        except BaseException:
            os.close(child)
            raise
        OUTPUTS[child] = (path, [p for p, _ in roots], identity(os.fstat(child)), source_ids)
        # Pin the freshly created output rather than relying on a mutable pathname.
        return child
    finally:
        os.close(fd)


def write(fd, name, obj):
    path, roots, expected, source_ids = OUTPUTS[fd]
    check = open_dir(path)
    try:
        if identity(os.fstat(check)) != expected or any(inside(p, path) or inside(path, p) for p in roots):
            raise ValueError("output identity changed")
    finally:
        os.close(check)
    outside_source_ancestry(fd, source_ids)
    text = obj if isinstance(obj, str) else json.dumps(obj, indent=2, sort_keys=True) + "\n"
    if len(text.encode()) > (5 * 1024 * 1024 if name.endswith('.md') else 16 * 1024 * 1024):
        raise ValueError("output budget exceeded")
    child = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    with os.fdopen(child, "w") as f:
        f.write(text)


def read_checkpoint(path, cancelled):
    """Precheck special types, nonblocking/no-follow open, descriptor recheck.

    O_NONBLOCK closes the stat/open FIFO replacement window. No data wrapper or
    read happens until the pinned descriptor is a private regular file matching
    the prechecked identity. FIFOs/devices/sockets/directories are never read.
    """
    if os.path.basename(path) != "private-checkpoint.json":
        raise ValueError("explicit recovery filename required")
    parent = open_dir(os.path.dirname(os.path.abspath(path)))
    state = None
    try:
        before = os.stat("private-checkpoint.json", dir_fd=parent, follow_symlinks=False)
        def acceptable(info):
            return stat.S_ISREG(info.st_mode) and info.st_size <= 16 * 1024 * 1024 and info.st_uid == os.getuid() and not info.st_mode & 0o077
        if cancelled() or not acceptable(before):
            raise ValueError("unsafe/cancelled recovery input")
        state = os.open("private-checkpoint.json", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=parent)
        info = os.fstat(state)
        if cancelled() or not acceptable(info) or identity(info) != identity(before):
            raise ValueError("checkpoint replaced or cancelled")
        # Chunked reads allow cooperative cancellation for a finite regular file.
        parts = []
        total = 0
        while True:
            if cancelled():
                raise ValueError("checkpoint reading cancelled")
            chunk = os.read(state, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > 16 * 1024 * 1024:
                raise ValueError("checkpoint grew beyond budget")
            parts.append(chunk)
        after = os.fstat(state)
        if (after.st_size, after.st_mtime_ns, after.st_ctime_ns) != (info.st_size, info.st_mtime_ns, info.st_ctime_ns):
            raise ValueError("checkpoint changed during read")
        return json.loads(b"".join(parts))
    finally:
        if state is not None:
            os.close(state)
        os.close(parent)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Explicit-root metadata assessment; no content reads or uploads")
    subs = parser.add_subparsers(dest="command", required=True)
    assess = subs.add_parser("assess")
    assess.add_argument("--root", action="append", required=True)
    assess.add_argument("--output", required=True)
    assess.add_argument("--max-files", type=int, default=1000000)
    assess.add_argument("--max-depth", type=int, default=64)
    assess.add_argument("--max-seconds", type=float, default=1800)
    assess.add_argument("--metadata-rate", type=float, default=100)
    assess.add_argument("--exclude", action="append", default=[])
    resume = subs.add_parser("resume")
    resume.add_argument("--checkpoint", required=True)
    resume.add_argument("--output", required=True, help="new directory; prior outputs preserved")
    args = parser.parse_args(argv)
    cancelled = False
    def stop(*_):
        nonlocal cancelled
        cancelled = True
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        if args.command == "resume":
            # The sole regular-file input open is explicit private recovery state,
            # never an assessed source or media body.
            checkpoint = read_checkpoint(args.checkpoint, lambda: cancelled)
            if checkpoint["schema_version"] != VERSION:
                raise ValueError("checkpoint version mismatch")
            p = policy(**checkpoint["policy"])
            if public_policy(p) != checkpoint["public_policy"]:
                raise ValueError("checkpoint policy changed; new assessment required")
            roots = roots_normalized([x[0] for x in checkpoint["roots"]])
            if [[p, i] for p, i in roots] != checkpoint["roots"]:
                raise ValueError("root identity changed; new assessment required")
        else:
            p = policy(max_files=args.max_files, max_depth=args.max_depth, max_seconds=args.max_seconds,
                       metadata_rate=args.metadata_rate, excludes=args.exclude)
            roots = roots_normalized(args.root)
        if not roots or len(roots) > 100:
            raise ValueError("root count out of bounds")
        fd = output_dir(args.output, roots)
        try:
            r = run(roots, p, cancelled=lambda: cancelled, progress=lambda x: print(json.dumps(x), file=sys.stderr))
            write(fd, "assessment.json", r)
            write(fd, "assessment.md", markdown(r))
            write(fd, "suggestions.json", suggestions(r))
            write(fd, "private-checkpoint.json", {"schema_version": VERSION, "roots": roots, "policy": p, "public_policy": public_policy(p),
                                                    "strategy": "rescan-all-replace-aggregates"})
        finally:
            os.close(fd)
        return 0 if r["status"] == "complete" else 130 if r["status"] == "cancelled" else 2
    except (OSError, ValueError, KeyError, TypeError):
        print("Assessment could not start/save safely; check root access, fresh output and checkpoint policy.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
