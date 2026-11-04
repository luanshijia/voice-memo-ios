"""Disable SPED in the pinned LiveKit source; reject unexpected dependency changes."""
import argparse
import hashlib
from pathlib import Path
import stat
import subprocess

REVISION = "93a7251057bdb6a80a7b1f6d11464d578ebdc09b"
SOURCE_SHA256 = "631106d3659a9cdb962aa0201c0a8a1f92955a70b0cf744cbd42b18d1d275ef1"
ENABLED = b'LKRTCPeerConnectionFactory.configureFieldTrials("\\(kLKRTCFieldTrialIceHandshakeDtlsKey)/\\(kLKRTCFieldTrialEnabledValue)/")'
DISABLED = b'LKRTCPeerConnectionFactory.configureFieldTrials("\\(kLKRTCFieldTrialIceHandshakeDtlsKey)/Disabled/")'
RELATIVE_SOURCE = Path("Sources/LiveKit/Core/RTC.swift")


def patched_source(source):
    # Accept the exact upstream file or our exact one-line patch, never a fuzzy match.
    original = source.replace(DISABLED, ENABLED)
    if hashlib.sha256(original).hexdigest() != SOURCE_SHA256:
        raise ValueError("LiveKit RTC.swift differs from the reviewed 2.18.0 source")
    if original.count(ENABLED) != 1:
        raise ValueError("Expected exactly one SPED field-trial declaration")
    return original.replace(ENABLED, DISABLED)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    revision = subprocess.check_output(
        ["git", "-C", str(args.checkout), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != REVISION:
        raise ValueError("LiveKit checkout is not the reviewed 2.18.0 revision")
    path = args.checkout / RELATIVE_SOURCE
    source = path.read_bytes()
    expected = patched_source(source)
    if args.check:
        if source != expected:
            raise ValueError("SPED must be disabled before building VoiceMemo")
    elif source != expected:
        # SwiftPM marks dependency sources read-only. Only this reviewed file is writable briefly.
        mode = path.stat().st_mode
        path.chmod(mode | stat.S_IWUSR)
        try:
            path.write_bytes(expected)
        finally:
            path.chmod(mode)
    print("LiveKit 2.18.0 verified: WebRTC-IceHandshakeDtls/Disabled/; sha256="
          + hashlib.sha256(expected).hexdigest())


if __name__ == "__main__":
    main()
