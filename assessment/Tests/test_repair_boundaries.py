"""Independent HOLD reproductions plus controls; every child reaped in finally."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from test_assessment import SOURCE, m


class RepairBoundaries(unittest.TestCase):
    def test_creation_open_replacement_never_exports_into_source(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(os.path.realpath(temp))
            source = base / "source"
            source.mkdir()
            (source / "tiny.mov").write_bytes(b"abc")
            output = base / "raced"
            # The old creation/open race is now unreachable from assess.
            with patch.object(m, "output_dir", side_effect=AssertionError("scanner created output")), \
                 patch.object(m, "write", side_effect=AssertionError("scanner wrote output")), \
                 patch.object(m, "stream_only"), patch.object(m.sys, "stdout"):
                code = m.main(["assess", "--root", str(source), "--metadata-rate", "10000"])
            self.assertEqual(sorted(p.name for p in source.iterdir()), ["tiny.mov"])
            self.assertEqual(code, 0)
            self.assertFalse(output.exists())
            self.assertEqual((source / "tiny.mov").read_bytes(), b"abc")

    def child(self, script, checkpoint, output):
        proc = subprocess.Popen([sys.executable, "-B", "-c", script, str(SOURCE), str(checkpoint), str(output)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            try:
                stdout, stderr = proc.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.communicate(timeout=.25)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.communicate(timeout=1)
                self.fail("nonregular recovery blocked before type validation")
            self.assertEqual(proc.returncode, 1, stderr)
            self.assertFalse(output.exists())
            self.assertIsNotNone(proc.poll())
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.communicate(timeout=1)
            self.assertIsNotNone(proc.poll(), "fixture child left alive")

    def test_fifo_checkpoint_rejects_without_blocking_or_child_leak(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(os.path.realpath(temp))
            state = base / "private-checkpoint.json"
            os.mkfifo(state, 0o600)
            self.child("import runpy,sys; sys.argv=[sys.argv[1],'resume','--checkpoint',sys.argv[2],'--output',sys.argv[3]]; runpy.run_path(sys.argv[0],run_name='__main__')", state, base / "out")

    def test_checkpoint_regular_to_fifo_open_race_rejects(self):
        script = '''import importlib.util,os,sys
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('repair',sys.argv[1]); m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
old=os.open
def race(name,flags,*args,**kwargs):
 if name=='private-checkpoint.json' and kwargs.get('dir_fd') is not None:
  os.unlink(sys.argv[2]);os.mkfifo(sys.argv[2],0o600)
 return old(name,flags,*args,**kwargs)
with patch.object(m.os,'open',side_effect=race):
 raise SystemExit(m.main(['resume','--checkpoint',sys.argv[2],'--output',sys.argv[3]]))
'''
        with tempfile.TemporaryDirectory() as temp:
            base = Path(os.path.realpath(temp))
            state = base / "private-checkpoint.json"
            state.write_text("{}")
            state.chmod(0o600)
            self.child(script, state, base / "out")

    def test_directory_checkpoint_rejected(self):
        script = "import runpy,sys; sys.argv=[sys.argv[1],'resume','--checkpoint',sys.argv[2],'--output',sys.argv[3]]; runpy.run_path(sys.argv[0],run_name='__main__')"
        with tempfile.TemporaryDirectory() as temp:
            base = Path(os.path.realpath(temp))
            state = base / "private-checkpoint.json"
            state.mkdir(mode=0o700)
            self.child(script, state, base / "out")

    def test_socket_and_device_types_rejected_before_any_open_or_read(self):
        # Actual AF_UNIX fixture binding was denied by the sandbox and stopped.
        # Inject metadata for other special types; sentinel proves no body open.
        for kind in (stat.S_IFSOCK, stat.S_IFCHR, stat.S_IFBLK):
            with tempfile.TemporaryDirectory() as temp:
                state = Path(os.path.realpath(temp)) / "private-checkpoint.json"
                info = SimpleNamespace(st_mode=kind | 0o600, st_size=0, st_uid=os.getuid())
                old_open = os.open
                def no_body(name, *args, **kwargs):
                    self.assertNotEqual(name, "private-checkpoint.json", "special input opened")
                    return old_open(name, *args, **kwargs)
                with patch.object(m.os, "stat", return_value=info), patch.object(m.os, "open", side_effect=no_body), patch.object(m.os, "read", side_effect=AssertionError("special input read")):
                    with self.assertRaises(ValueError):
                        m.read_checkpoint(str(state), lambda: False)

    def test_sigterm_during_checkpoint_read_exits_and_reaps(self):
        script = '''import importlib.util,os,signal,sys
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('repair',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
old=os.read
def stop(fd,size):
 value=old(fd,size);os.kill(os.getpid(),signal.SIGTERM);return value
with patch.object(m.os,'read',side_effect=stop):
 raise SystemExit(m.main(['resume','--checkpoint',sys.argv[2],'--output',sys.argv[3]]))
'''
        with tempfile.TemporaryDirectory() as temp:
            base = Path(os.path.realpath(temp))
            state = base / "private-checkpoint.json"
            state.write_text("{}")
            state.chmod(0o600)
            self.child(script, state, base / "out")

    def test_explicit_nested_device_not_normalized_away(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(os.path.realpath(temp))
            nested = base / "nested"
            nested.mkdir()
            with patch.object(m, "identity", side_effect=[[1, 11], [2, 22]]):
                roots = m.roots_normalized([str(base), str(nested)])
            self.assertEqual(len(roots), 2)


if __name__ == "__main__":
    unittest.main()
