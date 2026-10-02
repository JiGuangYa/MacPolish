#!/usr/bin/env python3
"""Run an opt-in native window/menu probe without ever blocking keyboard input."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def run(*args: str) -> None:
    subprocess.run(args, cwd=ROOT, check=True)


def is_probe_running(pid: int | None, executable: Path) -> bool:
    if pid is None or pid <= 1:
        return False
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
    return result.returncode == 0 and Path(result.stdout.strip()) == executable


def verify(output: Path, configuration: str, scope: str) -> None:
    run("swift", "build", "-c", configuration, "--product", "MacPolishWindowVerification")
    binary_directory = Path(subprocess.check_output(["swift", "build", "-c", configuration, "--show-bin-path"], cwd=ROOT, text=True).strip())
    with tempfile.TemporaryDirectory(prefix="MacPolish-window-probe-", dir=ROOT / ".build") as temporary:
        staging = Path(temporary)
        app = staging / "MacPolish Window Verification.app"
        executable = app / "Contents/MacOS/MacPolishWindowVerification"
        resources = app / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        shutil.copy2(binary_directory / executable.name, executable)
        shutil.copytree(binary_directory / "MacPolish_MacPolishKit.bundle", resources / "MacPolish_MacPolishKit.bundle")
        metadata = {
            "CFBundleExecutable": executable.name,
            "CFBundleIdentifier": "com.jiguang.MacPolish.WindowVerification",
            "CFBundleName": "MacPolish Window Verification",
            "CFBundlePackageType": "APPL",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["en"],
            "LSMinimumSystemVersion": "13.0",
            "MacPolishWindowVerification": True,
        }
        with (app / "Contents/Info.plist").open("wb") as target:
            plistlib.dump(metadata, target)
        run("codesign", "--force", "--sign", "-", str(app))
        result_path = staging / "result.json"
        pid_path = staging / "result.json.pid"
        stage_path = staging / "result.json.stage"
        error_log = staging / "stderr.log"
        error_log.touch()
        pid = None
        report_published = False
        try:
            # A background-only launch is intentionally not granted focus by
            # recent macOS versions. Use a normal foreground app launch and
            # remember the previous app for a cooperative handoff on exit.
            previous_pid = subprocess.check_output(["swift", "-e",
                "import AppKit; print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"], text=True).strip()
            run("open", "-n", str(app), "--stderr", str(error_log), "--args", "--result", str(result_path), "--previous-app", previous_pid,
                "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES", *([f"--{scope}-only"] if scope != "all" else []))
            deadline = time.monotonic() + 40
            while not result_path.exists():
                if pid is None and pid_path.exists():
                    pid = int(pid_path.read_text())
                if pid is not None and not is_probe_running(pid, executable):
                    raise RuntimeError("The native probe exited without a verification report.")
                if time.monotonic() >= deadline:
                    raise RuntimeError("The native probe did not return a report within 40 seconds.")
                time.sleep(0.1)
            report = json.loads(result_path.read_text())
            pid = int(report["processIdentifier"])
            report["configuration"] = configuration
            report["scope"] = scope
            report["verifiedAt"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
            output.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", prefix=".window-verification-", dir=output.parent, delete=False) as target:
                json.dump(report, target, ensure_ascii=False, indent=2)
                target.write("\n")
                replacement = Path(target.name)
            replacement.replace(output)
            report_published = True
            if report["status"] != "passed":
                raise RuntimeError(f"Native window verification failed: {report.get('error')}. Report: {output}")
            print(f"Verified {len(report['checks'])} native window/menu checks without installing an event tap.", flush=True)
            print(f"Report: {output}", flush=True)
        except BaseException as error:
            if not report_published:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps({
                    "status": "failed", "error": str(error), "processIdentifier": pid,
                    "configuration": configuration,
                    "scope": scope,
                    "verifiedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    "lastStage": stage_path.read_text() if stage_path.exists() else "not initialized",
                    "standardError": error_log.read_text(errors="replace")[-16_000:],
                }, indent=2) + "\n")
            raise
        finally:
            # Only act on the PID and exact executable path of this test app.
            if pid is None and pid_path.exists():
                pid = int(pid_path.read_text())
            deadline = time.monotonic() + 3
            while is_probe_running(pid, executable) and time.monotonic() < deadline:
                time.sleep(0.1)
            if is_probe_running(pid, executable):
                os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 3
                while is_probe_running(pid, executable) and time.monotonic() < deadline:
                    time.sleep(0.1)
                if is_probe_running(pid, executable):
                    raise RuntimeError(f"Native probe {pid} did not terminate; its executable is {executable}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Briefly show native test windows and invoke real MacPolish menus. Keyboard input is never intercepted.")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/window-verification.json")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    scope_group = parser.add_mutually_exclusive_group()
    scope_group.add_argument("--settings-only", action="store_true", help="Run only the native Settings accessibility checks.")
    scope_group.add_argument("--shield-only", action="store_true", help="Run only the shield exit accessibility checks in an ordinary small window.")
    args = parser.parse_args()
    scope = "settings" if args.settings_only else "shield" if args.shield_only else "all"
    output = args.output.expanduser().resolve()
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({"status": "running", "configuration": args.configuration,
            "scope": scope,
            "startedAt": datetime.now(timezone.utc).isoformat(timespec="seconds")}, indent=2) + "\n")
        verify(output, args.configuration, scope)
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError, KeyboardInterrupt) as error:
        # A build or cleanup failure must not leave an earlier passing report.
        try:
            report = json.loads(output.read_text()) if output.exists() else {}
            report.update(status="failed", error=str(error) or "Interrupted", configuration=args.configuration)
            report["scope"] = scope
            report["verifiedAt"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
            output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        except (OSError, ValueError):
            pass
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
