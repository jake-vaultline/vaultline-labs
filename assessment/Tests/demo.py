"""Generate shareable synthetic outputs; private fixture/checkpoint never exported."""
import json
import os
from pathlib import Path
import sys
import tempfile

from test_assessment import m

destination = Path(sys.argv[1])
destination.mkdir()
with tempfile.TemporaryDirectory(prefix="assessment-demo-") as temp:
    root = Path(os.path.realpath(temp)) / "PRIVATE_CLIENT_CANARY"
    root.mkdir()
    for n in range(3):
        d = root / f"PRIVATE_SHOOT_{n}"
        d.mkdir()
        (d / "PRIVATE_NAME.mov").write_bytes(b"synthetic")
        (d / "PRIVATE_NAME.prproj").write_bytes(b"not a parsed project")
    r = m.run(m.roots_normalized([str(root)]), m.policy(metadata_rate=10000))
    suggested = m.suggestions(r, human={"additionalNotes": "PRIVATE unsaved human note"})
    exports = {"assessment.json": json.dumps(r, indent=2, sort_keys=True) + "\n",
               "assessment.md": m.markdown(r), "suggestions.json": json.dumps(suggested, indent=2, sort_keys=True) + "\n"}
    for name, text in exports.items():
        assert "PRIVATE" not in text and str(root) not in text
        (destination / name).write_text(text)
