#!/usr/bin/env python3
"""Controlled physical-device test; streams Settings without saving screen images.

Build first: cargo build --locked --manifest-path Backend/Cargo.toml --bins
Keep Camera closed during the test. --crash exits without any native cleanup.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=45)
    parser.add_argument("--crash", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 600:
        parser.error("--seconds must be 1...600")
    binaries = Path(__file__).resolve().parent.parent / "Backend/target/debug"

    def state():
        result = subprocess.run(
            [str(binaries / "media-status")], capture_output=True, text=True,
            check=True, timeout=20,
        )
        value = json.loads(result.stdout)
        if not isinstance(value.get("sessions"), list):
            raise RuntimeError("Unrecognized session status; cannot establish release")
        return value

    if state()["sessions"]:
        raise SystemExit("An existing stream is active. Close its client before testing.")
    command = [str(binaries / "probe"), str(args.seconds), "--usb-only"]
    if args.crash:
        command.append("--crash")
    print(f"Starting {args.seconds}s USB session; keep Camera closed", flush=True)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        output, _ = process.communicate(timeout=args.seconds + 35)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        process.kill()
        output, _ = process.communicate()
    ended = time.monotonic()
    # Probe output includes a device name; omit that line from this report.
    for line in output.splitlines():
        if not line.startswith("Device:"):
            print(line, flush=True)
    if process.returncode != 0:
        print("Stream test failed; still checking expiry before exiting", flush=True)
    # Check even after a stream failure so a failed test doesn't hide leftover sessions.
    while time.monotonic() - ended < 40:
        value = state()
        elapsed = time.monotonic() - ended
        print(f"afterExit={elapsed:.2f}s streams={len(value['sessions'])} "
              f"running={value['running']}", flush=True)
        if not value["sessions"] and value["running"] is False:
            print("No media sessions remain. Physical Camera preview still needs checking.", flush=True)
            return 0 if process.returncode == 0 and elapsed <= 30 else 1
        time.sleep(1)
    print("FAIL: release was not confirmed within 40 seconds", flush=True)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
