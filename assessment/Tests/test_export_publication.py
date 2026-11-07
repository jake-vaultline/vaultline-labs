"""Eight retained late-publication scenarios now exercise the no-write scanner.

The historical export-open race failures remain on c92c2bb1. The approved
contract removes those opens from assess rather than claiming movable-output
confinement. Export's separate explicit writing boundary is tested below.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_assessment import SOURCE, m


ARTIFACTS = ("assessment.json", "assessment.md", "suggestions.json", "private-checkpoint.json")


def metadata(directory):
    return sorted((p.name, p.lstat().st_size, p.lstat().st_mtime_ns)
                  for p in directory.iterdir())


class ExportPublicationTests(unittest.TestCase):
    def race(self, artifact, ancestor):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(os.path.realpath(temp))
            source = base / "source"
            source.mkdir()
            (source / "synthetic.mov").write_bytes(b"abc")
            parent = base / "destination-parent"
            parent.mkdir()
            output = parent / "output"
            output.mkdir()
            relocated = source / "relocated"
            observed = {}
            original_emit = m.emit_report
            original_open = os.open

            def publication(report, stream):
                observed["attempted"] = True
                (parent if ancestor else output).rename(relocated)
                observed["moved_output"] = relocated / "output" if ancestor else relocated
                observed["before"] = metadata(observed["moved_output"])
                original_emit(report, stream)

            def no_file_write(name, flags, *args, **kwargs):
                self.assertFalse(flags & (os.O_CREAT | os.O_WRONLY | os.O_RDWR | os.O_TRUNC),
                                 "scanner attempted file mutation at former %s seam" % artifact)
                return original_open(name, flags, *args, **kwargs)

            read_fd, write_fd = os.pipe()
            diagnostic_read, diagnostic_write = os.pipe()
            try:
                with os.fdopen(write_fd, "w") as stream, os.fdopen(diagnostic_write, "w") as diagnostics:
                    with patch.object(m.sys, "stdout", stream), patch.object(m.sys, "stderr", diagnostics), patch.object(m, "emit_report", side_effect=publication), \
                         patch.object(m.os, "open", side_effect=no_file_write), \
                         patch.object(m, "output_dir", side_effect=AssertionError("scanner created output")), \
                         patch.object(m, "write", side_effect=AssertionError("scanner wrote output")), \
                         patch.object(m, "read_checkpoint", side_effect=AssertionError("scanner read recovery body")):
                        code = m.main(["assess", "--root", str(source), "--metadata-rate", "10000"])
                report = json.loads(os.read(read_fd, m.MAX_REPORT_BYTES))
            finally:
                os.close(read_fd)
                os.close(diagnostic_read)
            self.assertTrue(observed.get("attempted"), "actual stdout-publication seam not reached")
            self.assertEqual(metadata(observed["moved_output"]), observed["before"],
                             "publication changed source entries after relocation (exit %s)" % code)
            self.assertEqual(code, 0)
            self.assertEqual(report["aggregates"]["path_entries"], 1)
            self.assertEqual((source / "synthetic.mov").read_bytes(), b"abc")
            for name in ARTIFACTS:
                self.assertFalse((observed["moved_output"] / name).exists())

    def test_output_move_at_each_former_export_open_changes_no_source_entry(self):
        for artifact in ARTIFACTS:
            with self.subTest(artifact=artifact):
                self.race(artifact, ancestor=False)

    def test_ancestor_move_at_each_former_export_open_changes_no_source_entry(self):
        for artifact in ARTIFACTS:
            with self.subTest(artifact=artifact):
                self.race(artifact, ancestor=True)


class StreamAndExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(os.path.realpath(self.temp.name))
        self.base.chmod(0o700)
        self.source = self.base / "PRIVATE_SOURCE_CANARY"
        self.source.mkdir()
        (self.source / "PRIVATE_FILE_CANARY.mov").write_bytes(b"abc")
        self.command = [sys.executable, "-B", str(SOURCE)]

    def tearDown(self):
        self.temp.cleanup()

    def scan(self):
        result = subprocess.run(self.command + ["assess", "--root", str(self.source), "--metadata-rate", "10000"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def export(self, raw, output):
        return subprocess.run(self.command + ["export", "--output", str(output)], input=raw,
                              capture_output=True, text=True, timeout=5)

    def test_stdout_report_and_separate_private_export(self):
        before = metadata(self.source)
        raw = self.scan()
        self.assertEqual(metadata(self.source), before)
        self.assertEqual(sorted(p.name for p in self.base.iterdir()), [self.source.name])
        output = self.base / "export"
        result = self.export(raw, output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(sorted(p.name for p in output.iterdir()), sorted(ARTIFACTS[:3]))
        self.assertEqual(json.loads((output / "assessment.json").read_text()), json.loads(raw))
        for p in output.iterdir():
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("PRIVATE_SOURCE_CANARY", p.read_text())
            self.assertNotIn("PRIVATE_FILE_CANARY", p.read_text())
        self.assertEqual(metadata(self.source), before)

    def test_regular_stdout_refused_before_traversal_without_report_bytes(self):
        sink = self.source / "existing-sink"
        sink.write_text("SENTINEL")
        with sink.open("r+") as stream:
            result = subprocess.run(self.command + ["assess", "--root", str(self.source)],
                                    stdout=stream, stderr=subprocess.PIPE, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(sink.read_text(), "SENTINEL")

    def test_regular_stderr_refused_including_parser_errors(self):
        sink = self.source / "diagnostics"
        sink.write_text("SENTINEL")
        for args in (["assess", "--root", str(self.source)], ["assess", "--unknown"]):
            with sink.open("r+") as stream:
                result = subprocess.run(self.command + args, stdout=subprocess.PIPE, stderr=stream,
                                        text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertEqual(sink.read_text(), "SENTINEL")

    def test_parser_errors_do_not_copy_private_argument_values(self):
        result = subprocess.run(self.command + ["assess", "--private-argument", str(self.source)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(str(self.source), result.stdout + result.stderr)
        self.assertNotIn("private-argument", result.stdout + result.stderr)

    def test_export_refuses_preexisting_and_alias_destinations(self):
        raw = self.scan()
        existing = self.base / "existing"
        existing.mkdir()
        self.assertEqual(self.export(raw, existing).returncode, 1)
        alias = self.base / "alias"
        alias.symlink_to(self.base, target_is_directory=True)
        self.assertEqual(self.export(raw, alias / "new").returncode, 1)
        self.assertFalse((self.base / "new").exists())

    def test_export_requires_owner_private_parent(self):
        parent = self.base / "public-parent"
        parent.mkdir(mode=0o755)
        self.assertEqual(self.export(self.scan(), parent / "new").returncode, 1)
        self.assertFalse((parent / "new").exists())

    def test_export_rejects_checkpoint_unknown_fields_duplicates_and_nan(self):
        raw = self.scan()
        report = json.loads(raw)
        bad = ["{}", json.dumps({"schema_version": m.VERSION, "roots": [[str(self.source), None]], "policy": {}})]
        unknown = dict(report, private_checkpoint={"path": str(self.source)})
        bad.append(json.dumps(unknown))
        bad.append(raw.replace('"schema_version":', '"schema_version":"duplicate", "schema_version":', 1))
        bad.append(raw.replace('"logical_bytes": 3', '"logical_bytes": NaN', 1))
        for number, value in enumerate(bad):
            output = self.base / ("bad" + str(number))
            self.assertEqual(self.export(value, output).returncode, 1)
            self.assertFalse(output.exists())

    def test_export_rejects_noninteger_counts_and_wrong_aliases(self):
        report = json.loads(self.scan())
        for field, value in (("path_entries", True), ("logical_bytes", -1)):
            original = report["aggregates"][field]
            report["aggregates"][field] = value
            self.assertEqual(self.export(json.dumps(report), self.base / field).returncode, 1)
            report["aggregates"][field] = original
        report["roots"][0]["alias"] = str(self.source)
        self.assertEqual(self.export(json.dumps(report), self.base / "alias-out").returncode, 1)

    def test_export_rejects_private_free_text_and_overflowed_float(self):
        baseline = json.loads(self.scan())
        for number, field in enumerate(("limitations", "histogram", "mean")):
            report = json.loads(json.dumps(baseline))
            if field == "limitations":
                report["limitations"].append(str(self.source))
            elif field == "histogram":
                report["aggregates"]["extension_bytes"]["PRIVATE_FILE_CANARY"] = 1
            else:
                report["aggregates"]["mean_file_bytes"] = float("inf")
            self.assertEqual(self.export(json.dumps(report), self.base / ("private" + str(number))).returncode, 1)

    def test_export_input_bound_checked_before_output_creation(self):
        output = self.base / "over-budget"
        with patch.object(m, "MAX_REPORT_BYTES", 64):
            import io
            with self.assertRaises(ValueError):
                m.read_report(io.StringIO(" " * 65))
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
