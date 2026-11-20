#!/usr/bin/env python3
"""Best-effort xcresult evidence extraction; never substitutes for xcodebuild status."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile


CRASH_SUMMARY_LIMIT = 5 * 1024 * 1024


def unwrap(value):
    if isinstance(value, dict):
        if "_value" in value:
            return value["_value"]
        if "_values" in value:
            return [unwrap(item) for item in value["_values"]]
        return {key: unwrap(item) for key, item in value.items() if key != "_type"}
    if isinstance(value, list):
        return [unwrap(item) for item in value]
    return value


def count(value):
    # Missing or malformed counts stay unknown, rather than becoming zero passes.
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def normalize_summary(data):
    data = unwrap(data)
    modern = any(key in data for key in ("passedTests", "failedTests", "skippedTests"))
    metrics = data if modern else data.get("metrics", {})
    passed = count(metrics.get("passedTests")) if modern else None
    failed = count(metrics.get("failedTests" if modern else "testsFailedCount"))
    skipped = count(metrics.get("skippedTests" if modern else "testsSkippedCount"))
    total = count(metrics.get("totalTestCount" if modern else "testsCount"))
    # Legacy metrics expose total, failures and skips, rather than a pass count.
    if not modern and None not in (total, failed, skipped) and total >= failed + skipped:
        passed = total - failed - skipped
    failures = (data.get("testFailures", []) if modern else data.get("issues", {}).get("testFailureSummaries", [])) or []
    failures = [{"name": item.get("testIdentifier") or item.get("testName") or
                 item.get("testCaseName") or "Unnamed test",
                 "message": item.get("failureText") or item.get("message") or "No failure message exported"}
                for item in failures if isinstance(item, dict)]
    return {"passed": passed, "failed": failed, "skipped": skipped, "total": total,
            "result": data.get("result", "unavailable"), "failures": failures,
            "environment": data.get("devicesAndConfigurations") or data.get("environmentDescription")}


def crash_summary(path):
    # Apply the same bound to reports exported directly and inside device ZIPs.
    # Read one extra byte so a growing or truncated file cannot bypass the limit.
    with path.open("rb") as report:
        raw = report.read(CRASH_SUMMARY_LIMIT + 1)
    if len(raw) > CRASH_SUMMARY_LIMIT:
        raise ValueError("Crash report exceeds 5 MiB summary limit")
    return parse_crash(raw.decode(errors="replace"), path.suffix)


def parse_crash(text, suffix):
    if suffix == ".ips":
        # Apple .ips reports may contain a metadata JSON object, then a report object.
        decoder, offset, objects = json.JSONDecoder(), 0, []
        while offset < len(text):
            offset += len(text[offset:]) - len(text[offset:].lstrip())
            if offset == len(text):
                break
            item, used = decoder.raw_decode(text[offset:])
            objects.append(item)
            offset += used
        report = next((item for item in objects if isinstance(item, dict) and "threads" in item), {})
        threads = report.get("threads", [])
        fault = report.get("faultingThread")
        thread = next((item for item in threads if item.get("triggered")), None)
        if thread is None and isinstance(fault, int) and 0 <= fault < len(threads):
            thread = threads[fault]
        lines = [f"{report.get('procName', 'Process')}: {json.dumps(report.get('exception', {}), sort_keys=True)}"]
        if thread is None:
            return "\n".join(lines + ["Crashed thread unavailable in exported report"])
        for frame in thread.get("frames", [])[:12]:
            lines.append(str(frame.get("symbol") or
                             f"image {frame.get('imageIndex', '?')} + {frame.get('imageOffset', '?')}"))
        return "\n".join(lines)
    match = re.search(r"^Thread \d+ Crashed[^\n]*\n(?:[^\n]+\n?){0,12}", text, re.MULTILINE)
    header = [line for line in text.splitlines() if line.startswith(("Process:", "Exception Type:", "Termination Reason:"))]
    return "\n".join(header + [match.group(0).rstrip() if match else "Crashed thread unavailable in exported report"])


def extract(command, output, warnings, timeout=15):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        output.write_text(result.stdout)
        output.with_suffix(output.suffix + ".stderr.log").write_text(result.stderr)
        if result.returncode:
            warnings.append(f"{output.name}: command exited {result.returncode}; see stderr log")
            return None
        return result.stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        warnings.append(f"{output.name}: {error}")
        if isinstance(error, subprocess.TimeoutExpired):
            stdout, stderr = error.stdout or "", error.stderr or ""
            output.write_text(stdout.decode(errors="replace") if isinstance(stdout, bytes) else stdout)
            stderr = stderr.decode(errors="replace") if isinstance(stderr, bytes) else stderr
        else:
            stderr = ""
        output.with_suffix(output.suffix + ".stderr.log").write_text(f"{error}\n{stderr}")
        return None


def collect_bundle(bundle, artifacts):
    name = bundle.stem
    directory = artifacts / "diagnostics" / name
    directory.mkdir(parents=True, exist_ok=True)
    warnings = []
    normalized = normalize_summary({})
    for legacy in (False, True):
        command = (["xcrun", "xcresulttool", "get", "--legacy", "--format", "json", "--path", str(bundle)]
                   if legacy else ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)])
        output = directory / ("legacy.json" if legacy else "summary.json")
        raw = extract(command, output, warnings)
        if raw:
            try:
                normalized = normalize_summary(json.loads(raw))
                if any(normalized[key] is not None for key in ("passed", "failed", "skipped")):
                    break
                warnings.append(f"{output.name}: no recognized test counts")
            except (ValueError, TypeError, AttributeError) as error:
                warnings.append(f"{output.name}: cannot parse summary: {error}")
    for kind in ("attachments", "diagnostics"):
        extract(["xcrun", "xcresulttool", "export", kind, "--path", str(bundle),
                 "--output-path", str(directory / kind)], directory / f"export-{kind}.log", warnings, timeout=30)
    normalized.update(run=name, warnings=warnings)
    return normalized


def inline(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def create_report(artifacts, extract_bundles=True):
    artifacts.mkdir(parents=True, exist_ok=True)
    runs = {}
    for path in sorted(artifacts.glob("*.status.json")):
        try:
            status = json.loads(path.read_text())
            runs[status["run"]] = {**normalize_summary({}), **status, "warnings": []}
        except (ValueError, KeyError, TypeError) as error:
            runs[path.stem] = {**normalize_summary({}), "run": path.stem, "warnings": [str(error)]}
    for bundle in sorted(artifacts.glob("*.xcresult")):
        if bundle.stem not in ("Build", "Archive") and extract_bundles:
            try:
                runs[bundle.stem] = {**runs.get(bundle.stem, {}), **collect_bundle(bundle, artifacts)}
            except Exception as error:
                runs.setdefault(bundle.stem, {**normalize_summary({}), "run": bundle.stem, "warnings": []})
                runs[bundle.stem]["warnings"].append(f"Bundle extraction failed: {error}")
    if not runs:
        runs["LittleMoments"] = {**normalize_summary({}), "run": "LittleMoments", "warnings": []}
    for name, run in runs.items():
        if not (artifacts / f"{name}.xcresult").exists():
            run["warnings"].append("Result bundle missing; inspect build/test logs. Counts are unavailable.")
    report = ["## iOS test evidence", "", "Build and test step exit codes determine job success. Missing counts are **unavailable**, never zero passes.", ""]
    version = artifacts / "xcode-version.txt"
    if version.exists():
        report += [f"Xcode: {inline(version.read_text().strip())}", ""]
    inventory = artifacts / "simulator-device.json"
    if inventory.exists():
        try:
            devices = json.loads(inventory.read_text()).get("devices", {})
            for runtime, candidates in devices.items():
                for device in candidates:
                    if device.get("udid") == os.environ.get("SIMULATOR_ID"):
                        report += [f"Device: {inline(device.get('name'))}; OS: {inline(runtime)}; UDID: `{inline(device['udid'])}`", ""]
        except (ValueError, AttributeError):
            report += ["Device metadata unavailable; see simulator-device.json.", ""]
    report += ["| Run | xcodebuild exit | Result | Passed | Failed | Skipped |", "| --- | --- | --- | --- | --- | --- |"]
    for name, run in sorted(runs.items()):
        values = [name, run.get("exitCode"), run["result"], run["passed"], run["failed"], run["skipped"]]
        report.append("| " + " | ".join("unavailable" if value is None else inline(value) for value in values) + " |")
    for name, run in sorted(runs.items()):
        report += ["", f"### {inline(name)}"]
        for failure in run["failures"]:
            report += [f"- **{inline(failure['name'])}**: {inline(failure['message'])}"]
        for warning in run["warnings"]:
            report += [f"- Evidence warning: {inline(warning)}"]
        if run.get("environment"):
            report += [f"- xcresult environment: {inline(json.dumps(run['environment'], sort_keys=True))}"]
    crashes = []
    for path in sorted(artifacts.rglob("*")):
        if path.is_file() and path.suffix in (".ips", ".crash"):
            try:
                summary = crash_summary(path)
            except (ValueError, TypeError, KeyError, AttributeError, OSError) as error:
                summary = f"Could not parse crash report: {error}; inspect original report."
            crashes.append({"path": str(path.relative_to(artifacts)), "summary": summary})
            report += ["", f"### Crash: {inline(path.relative_to(artifacts))}", "", "```text", summary.replace("```", "~~~"), "```"]
        elif path.is_file() and path.suffix == ".zip":
            # xcresulttool may package each device's diagnostics in a ZIP. Read only
            # bounded crash entries without extracting arbitrary paths to disk.
            try:
                with zipfile.ZipFile(path) as archive:
                    for entry in archive.infolist():
                        suffix = Path(entry.filename).suffix
                        if suffix not in (".ips", ".crash"):
                            continue
                        label = f"{path.relative_to(artifacts)}!{entry.filename}"
                        try:
                            if entry.file_size > CRASH_SUMMARY_LIMIT:
                                raise ValueError("Crash report exceeds 5 MiB summary limit")
                            summary = parse_crash(archive.read(entry).decode(errors="replace"), suffix)
                        except (ValueError, TypeError, KeyError, AttributeError, OSError, RuntimeError) as error:
                            summary = f"Could not parse crash report: {error}; inspect original ZIP."
                        crashes.append({"path": label, "summary": summary})
                        report += ["", f"### Crash: {inline(label)}", "", "```text", summary.replace("```", "~~~"), "```"]
            except (OSError, zipfile.BadZipFile) as error:
                report += ["", f"Diagnostic ZIP unreadable: {inline(path.relative_to(artifacts))}: {inline(error)}"]
    if not crashes:
        report += ["", "No readable crash reports were exported. This does not establish that no crash occurred."]
    artifact = f"ios-results-{os.environ.get('GITHUB_RUN_ATTEMPT', 'local')}"
    report += ["", f"Evidence artifact: **{artifact}** (per-run xcresult bundles, status JSON, logs, attachments, diagnostics, and this summary)."]
    if os.environ.get("GITHUB_RUN_ID"):
        report += [f"[Workflow run and artifacts]({os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ['GITHUB_RUN_ID']})"]
    (artifacts / "test-summary.json").write_text(json.dumps({"runs": runs, "crashes": crashes}, indent=2) + "\n")
    markdown = "\n".join(report) + "\n"
    (artifacts / "test-summary.md").write_text(markdown)
    return markdown


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=Path("artifacts"))
    args = parser.parse_args()
    # Publish status/log evidence before potentially slow or damaged bundle exports.
    # If the diagnostics step is interrupted, this preliminary report still exists.
    preliminary = create_report(args.artifacts, extract_bundles=False)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        Path(step_summary).write_text(preliminary)
    markdown = create_report(args.artifacts)
    print(markdown)
    if step_summary:
        Path(step_summary).write_text(markdown)


if __name__ == "__main__":
    main()
