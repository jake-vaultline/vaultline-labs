"""100k synthetic metadata benchmark. Creates only disposable fixture entries."""
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys
import tempfile
import time

from test_assessment import m, SOURCE

with tempfile.TemporaryDirectory(prefix="assessment-100k-") as temp:
    base = Path(os.path.realpath(temp))
    root = base / "SyntheticArchive"
    root.mkdir()
    for n in range(100):
        d = root / f"batch{n}"
        d.mkdir()
        for k in range(1000):
            (d / f"clip{k}.mov").touch()
    started = time.monotonic()
    result = subprocess.run([sys.executable, "-B", str(SOURCE), "assess", "--root", str(root),
        "--metadata-rate", "10000"], capture_output=True, text=True)
    elapsed = time.monotonic() - started
    report = json.loads(result.stdout)
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    if sys.platform != "darwin":
        rss *= 1024
    output_bytes = len(result.stdout.encode())
    cancel_start = time.monotonic()
    r = m.run(m.roots_normalized([str(root)]), m.policy(metadata_rate=100),
              cancelled=lambda: time.monotonic() - cancel_start > .1)
    cancel_elapsed = time.monotonic() - cancel_start
    evidence = dict(platform=platform.platform(), machine=platform.machine(),
        processor=platform.processor(), python=platform.python_version(), fixture_entries=100000,
        scan_elapsed_seconds=elapsed, peak_child_rss_bytes=rss, output_and_state_bytes=output_bytes,
        report_bytes=len(m.markdown(report).encode()),
        observed_entries=report["aggregates"]["path_entries"], exit_code=result.returncode,
        cancel_ack_and_report_seconds=cancel_elapsed,
        budgets_pass=rss <= 512*1024*1024 and output_bytes <= 1024**3 and cancel_elapsed <= 1,
        limitations="Synthetic local metadata only; rate override 10000; kernel/NAS abort and provider IO unqualified")
    print(json.dumps(evidence, indent=2))
    if result.returncode or report["aggregates"]["path_entries"] != 100000 or not evidence["budgets_pass"]:
        raise SystemExit(1)
