"""Verify the contract bundle without access to the private parent repository."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
revision = json.loads((ROOT / "Contracts/revision.json").read_text(encoding="utf-8"))
assert revision["version"] == 1, "unsupported contract bundle"
for name, expected in revision["sha256"].items():
    data = (ROOT / name).read_bytes().replace(b"\r\n", b"\n")
    assert hashlib.sha256(data).hexdigest() == expected, name + " differs from contract bundle"
print("App contract bundle verified:", hashlib.sha256(
    (ROOT / "Contracts/revision.json").read_bytes().replace(b"\r\n", b"\n")).hexdigest())
