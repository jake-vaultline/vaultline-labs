"""Causal late-export-open races; source fixtures contain synthetic bytes only."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from test_assessment import m


ARTIFACTS = ("assessment.json", "assessment.md", "suggestions.json", "private-checkpoint.json")


def metadata(directory):
    """Observe entry metadata, never report/checkpoint or source file bodies."""
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
            relocated = source / "relocated"
            observed = {}
            original_open = os.open

            def late_open(name, flags, *args, **kwargs):
                if name == artifact and flags & os.O_CREAT and kwargs.get("dir_fd") is not None:
                    observed["attempted"] = True
                    try:
                        (parent if ancestor else output).rename(relocated)
                    except PermissionError:
                        # A kernel-enforced non-rename constraint is a safe outcome.
                        observed["blocked"] = True
                    else:
                        observed["moved_output"] = relocated / "output" if ancestor else relocated
                        observed["before"] = metadata(observed["moved_output"])
                return original_open(name, flags, *args, **kwargs)

            with patch.object(m.os, "open", side_effect=late_open):
                code = m.main(["assess", "--root", str(source), "--output", str(output),
                               "--metadata-rate", "10000"])
            self.assertTrue(observed.get("attempted"), "actual artifact-creation seam not reached")
            if observed.get("blocked"):
                self.assertEqual(code, 0)
                self.assertEqual(sorted(p.name for p in source.iterdir()), ["synthetic.mov"])
            else:
                self.assertEqual(metadata(observed["moved_output"]), observed["before"],
                                 "publication changed source entries after relocation (exit %s)" % code)
                self.assertEqual(code, 1, "relocated output must fail closed")

    def test_output_move_at_each_actual_export_open_changes_no_source_entry(self):
        for artifact in ARTIFACTS:
            with self.subTest(artifact=artifact):
                self.race(artifact, ancestor=False)

    def test_ancestor_move_at_each_actual_export_open_changes_no_source_entry(self):
        for artifact in ARTIFACTS:
            with self.subTest(artifact=artifact):
                self.race(artifact, ancestor=True)


if __name__ == "__main__":
    unittest.main()
