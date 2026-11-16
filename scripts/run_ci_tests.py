#!/usr/bin/env python3
"""Run each test pass once, preserving its exit code, log, and result bundle."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def stress_selectors(root):
    selectors = ["LittleMomentsTests/CameraModelTests", "LittleMomentsTests/MediaIntegrationTests"]
    recorder = root / "LittleMomentsTests/RollingRecorderTests.swift"
    if recorder.exists():
        source = recorder.read_text()
        # The five-minute/window/audio matrix belongs in the ordinary pass only.
        for method in ("testRolloverAndRepeatedSnapshotsPreserveFrameMarkers",
                       "testDelayedCompletionCannotCrossGeneration"):
            if f"func {method}(" not in source:
                raise RuntimeError(f"Production recorder stress selector disappeared: {method}")
            selectors.append(f"LittleMomentsTests/RollingRecorderTests/{method}")
    return selectors


def run_pass(root, artifacts, simulator, name, selectors, executable="xcodebuild"):
    bundle = "LittleMoments" if name == "ordinary" else name
    log = "tests.log" if name == "ordinary" else f"{name.lower()}.log"
    status_file = artifacts / f"{bundle}.status.json"
    command = [executable, "test-without-building", "-project", "LittleMoments.xcodeproj",
               "-scheme", "LittleMoments", "-configuration", "Debug", "-destination",
               f"platform=iOS Simulator,id={simulator}", "-derivedDataPath", "build/DerivedData",
               "-resultBundlePath", str(artifacts / f"{bundle}.xcresult"),
               "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES",
               "-default-test-execution-time-allowance", "120",
               "-maximum-test-execution-time-allowance", "180", "CODE_SIGNING_ALLOWED=NO"]
    command += [f"-only-testing:{selector}" for selector in selectors]
    status = {"run": bundle, "state": "started", "exitCode": None,
              "log": log, "selectors": selectors}
    status_file.write_text(json.dumps(status, indent=2) + "\n")
    with (artifacts / log).open("w") as output:
        try:
            process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in process.stdout:
                output.write(line)
                output.flush()
                print(line, end="", flush=True)
            process.stdout.close()
            code = process.wait()
        except OSError as error:
            output.write(f"Could not launch xcodebuild: {error}\n")
            code = 127
    status.update(state="completed", exitCode=code)
    status_file.write_text(json.dumps(status, indent=2) + "\n")
    return code if code >= 0 else 128 - code


def run_tests(root, artifacts, simulator, mode, iterations=3, executable="xcodebuild"):
    artifacts.mkdir(parents=True, exist_ok=True)
    if mode == "ordinary":
        return run_pass(root, artifacts, simulator, "ordinary", [], executable)
    if not 1 <= iterations <= 3:
        raise ValueError("Stress iterations must be between one and three")
    selectors = stress_selectors(root)
    for iteration in range(1, iterations + 1):
        code = run_pass(root, artifacts, simulator, f"Stress-{iteration}", selectors, executable)
        if code:
            return code  # Never retry a failing iteration or let later passes replace it.
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("ordinary", "stress"))
    parser.add_argument("--iterations", type=int, default=3)
    args = parser.parse_args()
    simulator = os.environ.get("SIMULATOR_ID")
    if not simulator:
        parser.error("SIMULATOR_ID is required")
    return run_tests(Path.cwd(), Path("artifacts").resolve(), simulator, args.mode, args.iterations)


if __name__ == "__main__":
    sys.exit(main())
