"""Behavioral fixtures: actual filesystem metadata plus fault injection, no media."""
import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "Sources" / "assessment.py"
spec = importlib.util.spec_from_file_location("assessment", SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class AssessmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(os.path.realpath(self.tmp.name))
        self.root = self.base / "ClientSecretCanary_Host_Username"
        self.root.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def scan(self, roots=None, hook=lambda *a: None, **kwargs):
        return m.run(m.roots_normalized(roots or [str(self.root)]),
                     m.policy(metadata_rate=10000, **kwargs), hook=hook)

    def test_known_metadata_packages_links_sparse_and_hardlinks(self):
        (self.root / ".hidden.mov").write_bytes(b"abc")
        (self.root / "private.prproj").write_bytes(b"four")
        os.link(self.root / ".hidden.mov", self.root / "linked.mov")
        sparse = self.root / "sparse.bin"
        with sparse.open("wb") as f:
            f.truncate(1024 * 1024)
        bundle = self.root / "project.fcpbundle"
        bundle.mkdir()
        (bundle / "nested.wav").write_bytes(b"ab")
        (self.root / "empty").mkdir()
        os.symlink(self.base, self.root / "escape")
        before = {str(p): p.stat().st_mtime_ns for p in self.root.rglob('*') if not p.is_symlink()}
        r = self.scan()
        a = r["aggregates"]
        self.assertEqual(a["path_entries"], 5)
        self.assertEqual(a["logical_bytes"], 1048588)
        self.assertEqual(a["project_artifacts"], 2)
        self.assertEqual(a["directories"], 2)
        self.assertEqual(a["skipped"]["link"], 1)
        if a["distinct_objects"] is not None:
            self.assertEqual(a["distinct_objects"], 4)
            self.assertEqual(a["distinct_logical_bytes"], 1048585)
        self.assertEqual(before, {str(p): p.stat().st_mtime_ns for p in self.root.rglob('*') if not p.is_symlink()})
        self.assertEqual(r["coverage"]["content_reads"], 0)

    def test_empty_and_overlap_dedup(self):
        (self.root / "nested").mkdir()
        (self.root / "nested" / "a.txt").write_bytes(b"1")
        roots = m.roots_normalized([str(self.root), str(self.root / "nested"), str(self.root)])
        self.assertEqual(len(roots), 1)
        self.assertEqual(self.scan([p for p, _ in roots])["aggregates"]["path_entries"], 1)
        empty = self.base / "empty"
        empty.mkdir()
        a = self.scan([str(empty)])["aggregates"]
        self.assertEqual(a["logical_bytes"], 0)
        self.assertIsNone(a["mean_file_bytes"])

    def test_faults_preserve_independent_roots_and_unknowns(self):
        (self.root / "a.mov").write_bytes(b"1")
        other = self.base / "ZOther"
        other.mkdir()
        (other / "a.mov").write_bytes(b"22")
        def hook(phase, path):
            if phase == "enumerate" and not path and active[0] == 1:
                raise PermissionError(errno.EACCES, "ClientSecretCanary denied")
            if phase == "root":
                active[0] += 1
            if phase == "identity":
                return False
        active = [0]
        r = self.scan([str(self.root), str(other)], hook=hook)
        self.assertEqual(r["status"], "partial")
        self.assertEqual(r["aggregates"]["logical_bytes"], 2)
        self.assertIsNone(r["aggregates"]["distinct_objects"])
        self.assertEqual(r["roots"][1]["status"], "complete")
        self.assertIsNone(r["coverage"]["unseen_bytes"])
        self.assertNotIn("ClientSecretCanary", json.dumps(r))

    def test_vanished_changed_disconnected_capacity_and_placeholder(self):
        for name in ["vanished", "changed", "resident", "disconnect"]:
            (self.root / name).write_bytes(b"a")
        def hook(phase, rel):
            if phase == "stat" and rel == "/vanished":
                raise FileNotFoundError(errno.ENOENT, "private")
            if phase == "after_stat" and rel == "/changed":
                (self.root / "changed").write_bytes(b"ab")
            if phase == "stat" and rel == "/disconnect":
                raise OSError(errno.ESTALE, "private")
            if phase == "capacity":
                raise OSError(errno.EIO, "private")
            if phase == "placeholder" and rel == "/resident":
                return True
        r = self.scan(hook=hook)
        self.assertEqual(r["status"], "partial")
        self.assertEqual(r["aggregates"]["path_entries"], 1)
        self.assertEqual(r["aggregates"]["placeholders"], 1)
        self.assertTrue(r["aggregates"]["errors"])
        for mount in r["mounts"]:
            self.assertIsNone(mount["total_bytes"])

    def test_directory_replacement_cannot_escape(self):
        target = self.root / "folder"
        target.mkdir()
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "notallowed").write_bytes(b"private")
        def hook(phase, rel):
            if phase == "before_open_dir":
                target.rmdir()
                target.symlink_to(outside, target_is_directory=True)
        r = self.scan(hook=hook)
        self.assertEqual(r["aggregates"]["path_entries"], 0)
        self.assertEqual(r["status"], "partial")

    def test_forbidden_content_and_network_operation_spies(self):
        import socket
        for name in ("media.mov", "project.prproj", "notes.txt"):
            (self.root / name).write_bytes(b"CANARY CONTENT MUST NOT OPEN")
        original = os.open
        opened = []
        def spy(path, flags, *args, **kwargs):
            self.assertTrue(flags & os.O_DIRECTORY, "regular source opened")
            self.assertTrue(flags & os.O_NOFOLLOW)
            opened.append(path)
            return original(path, flags, *args, **kwargs)
        with patch.object(os, "open", spy), patch("builtins.open", side_effect=AssertionError("content read")), patch.object(socket, "socket", side_effect=AssertionError("network")), patch.object(subprocess, "Popen", side_effect=AssertionError("probe/process")):
            r = self.scan()
        self.assertEqual(r["aggregates"]["path_entries"], 3)
        self.assertTrue(opened)

    def test_limits_exclusions_depth_and_bounded_patterns(self):
        for n in range(150):
            (self.root / ("秘密_CANARY_" + str(n) + ".oddprivateextension")).touch()
        (self.root / "excluded").mkdir()
        (self.root / "excluded" / "no").touch()
        d = self.root / "deep"
        d.mkdir()
        (d / "deeper").mkdir()
        (d / "deeper" / "never").touch()
        r = self.scan(excludes=["excluded*"], max_depth=1)
        self.assertEqual(r["aggregates"]["path_entries"], 150)
        self.assertEqual(r["status"], "partial")
        self.assertNotIn("oddprivateextension", json.dumps(r))
        self.assertEqual(self.scan(max_files=3)["aggregates"]["path_entries"], 3)

    def test_mapper_surface_conflicts_unknowns_redaction(self):
        for n in range(3):
            (self.root / ("ClientSecretCanary_" + str(n) + ".mov")).touch()
        r = self.scan()
        out = m.suggestions(r, human={"additionalNotes": "PRIVATE HUMAN"})
        values = {x["field"]: x for x in out["suggestions"]}
        self.assertEqual(values["additionalNotes"]["action"], "alternate_preserve_human")
        self.assertNotIn("connectionProtocol", values)
        for key in ("primaryContact", "sampleScope", "successCriteria", "networkPath", "aiTagging"):
            self.assertNotIn(key, values)
        combined = json.dumps(r) + m.markdown(r) + json.dumps(out)
        for private in (str(self.base), "ClientSecretCanary", "PRIVATE HUMAN"):
            self.assertNotIn(private, combined)
        self.assertFalse(out["save"])
        self.assertFalse(out["submit"])
        with self.assertRaises(ValueError):
            m.suggestions(r, surface="assigned-task")
        r["aggregates"]["extensions"]["RAWPRIVATE"] = 1
        with self.assertRaises(ValueError):
            m.suggestions(r)

    def cli(self, *args):
        return subprocess.run([sys.executable, str(SOURCE), *args], capture_output=True, text=True)

    def test_fresh_output_and_alias_rejection(self):
        self.assertEqual(self.cli("assess", "--root", str(self.root), "--output", str(self.root / "out")).returncode, 1)
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertEqual(self.cli("assess", "--root", str(alias), "--output", str(self.base / "out")).returncode, 1)
        out = self.base / "out"
        out.mkdir()
        self.assertEqual(self.cli("assess", "--root", str(self.root), "--output", str(out)).returncode, 1)
        parent_alias = self.base / "parentalias"
        parent_alias.symlink_to(self.base, target_is_directory=True)
        self.assertEqual(self.cli("assess", "--root", str(self.root), "--output", str(parent_alias / "new")).returncode, 1)

    def test_resume_reconciles_changed_directory_and_root_identity(self):
        (self.root / "first").write_bytes(b"1")
        out = self.base / "out"
        result = self.cli("assess", "--root", str(self.root), "--output", str(out), "--metadata-rate", "10000")
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / "first").unlink()
        (self.root / "second").write_bytes(b"22")
        checkpoint = out / "private-checkpoint.json"
        for number in range(2):
            resumed = self.base / f"resumed{number}"
            self.assertEqual(self.cli("resume", "--checkpoint", str(checkpoint), "--output", str(resumed)).returncode, 0)
            self.assertEqual(json.loads((resumed / "assessment.json").read_text())["aggregates"]["logical_bytes"], 2)
        self.assertEqual(checkpoint.stat().st_mode & 0o777, 0o600)
        self.root.rename(self.base / "oldroot")
        self.root.mkdir()
        self.assertEqual(self.cli("resume", "--checkpoint", str(checkpoint), "--output", str(self.base / "invalid")).returncode, 1)

    def test_cancel_latency_and_partial_export(self):
        for n in range(20):
            (self.root / str(n)).touch()
        started = time.monotonic()
        r = m.run(m.roots_normalized([str(self.root)]), m.policy(metadata_rate=1), cancelled=lambda: time.monotonic() - started > .1)
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(r["status"], "cancelled")
        fd = m.output_dir(str(self.base / "cancelled"), [(str(self.root), None)])
        try:
            m.write(fd, "assessment.md", m.markdown(r))
        finally:
            os.close(fd)
        self.assertLess(time.monotonic() - started, 5)
        self.assertNotIn("ClientSecretCanary", m.markdown(r))

    def test_output_replacement_fails_before_write(self):
        output = self.base / "out"
        fd = m.output_dir(str(output), [(str(self.root), None)])
        output.rename(self.base / "oldout")
        output.symlink_to(self.root, target_is_directory=True)
        try:
            with self.assertRaises(OSError):
                m.write(fd, "assessment.md", "never written")
        finally:
            os.close(fd)
        self.assertFalse((self.root / "assessment.md").exists())

    def test_unknown_policy_version_time_limit_and_distribution_counts(self):
        (self.root / "x.mov").write_bytes(b"four")
        with self.assertRaises(ValueError):
            m.policy(unknown=True)
        r = self.scan(max_seconds=.000001)
        self.assertEqual(r["status"], "partial")
        r = self.scan()
        self.assertEqual(r["aggregates"]["category_bytes"]["probable_video"], 4)
        self.assertEqual(r["aggregates"]["extension_bytes"]["mov"], 4)
        r["schema_version"] = "bad"
        with self.assertRaises(ValueError):
            m.suggestions(r)

    def test_checkpoint_changed_policy_is_rejected(self):
        out = self.base / "out"
        self.assertEqual(self.cli("assess", "--root", str(self.root), "--output", str(out)).returncode, 0)
        checkpoint = out / "private-checkpoint.json"
        state = json.loads(checkpoint.read_text())
        state["policy"]["madeUp"] = True
        checkpoint.write_text(json.dumps(state))
        self.assertEqual(self.cli("resume", "--checkpoint", str(checkpoint), "--output", str(self.base / "new")).returncode, 1)
        del state["policy"]["madeUp"]
        state["policy"]["max_files"] = 10
        checkpoint.write_text(json.dumps(state))
        self.assertEqual(self.cli("resume", "--checkpoint", str(checkpoint), "--output", str(self.base / "new2")).returncode, 1)

    def test_selected_project_package_and_missing_root(self):
        package = self.root / "edit.fcpbundle"
        package.mkdir()
        (package / "file.mov").touch()
        r = self.scan([str(package)])
        self.assertEqual(r["aggregates"]["project_artifacts"], 1)
        self.assertEqual(r["aggregates"]["path_entries"], 1)
        r = self.scan([str(self.root), str(self.base / "missing")])
        self.assertEqual(r["status"], "partial")
        self.assertEqual(r["aggregates"]["path_entries"], 1)

    def test_schema_contract_shape(self):
        schema = json.loads((SOURCE.parents[1] / "schema" / "aggregate-v1.schema.json").read_text())
        r = self.scan()
        # Validate the exported required/closed envelope and types without adding
        # a dependency. This is this contract's supported schema subset, not a
        # claim of a general JSON Schema implementation.
        def validate(value, rule):
            if "$ref" in rule:
                rule = schema["$defs"][rule["$ref"].split("/")[-1]]
            if "const" in rule:
                self.assertEqual(value, rule["const"])
            if "enum" in rule:
                self.assertIn(value, rule["enum"])
            types = rule.get("type", [])
            if isinstance(types, str):
                types = [types]
            mapping = {"object": dict, "array": list, "integer": int, "string": str, "number": (int, float), "null": type(None)}
            if types:
                self.assertTrue(any(isinstance(value, mapping[t]) for t in types))
            if isinstance(value, dict):
                self.assertTrue(set(rule.get("required", [])) <= set(value))
                properties = rule.get("properties", {})
                if rule.get("additionalProperties") is False:
                    self.assertFalse(set(value) - set(properties))
                if "maxProperties" in rule:
                    self.assertLessEqual(len(value), rule["maxProperties"])
                for key, item in value.items():
                    child = properties.get(key, rule.get("additionalProperties", {}))
                    if isinstance(child, dict):
                        validate(item, child)
            elif isinstance(value, list):
                self.assertLessEqual(len(value), rule.get("maxItems", len(value)))
                for item in value:
                    validate(item, rule.get("items", {}))
            elif isinstance(value, (int, float)):
                self.assertGreaterEqual(value, rule.get("minimum", value))
                self.assertLessEqual(value, rule.get("maximum", value))
            elif isinstance(value, str) and "pattern" in rule:
                self.assertRegex(value, rule["pattern"])
        validate(r, schema)


if __name__ == "__main__":
    unittest.main()
