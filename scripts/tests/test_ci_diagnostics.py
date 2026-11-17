import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).parent / "fixtures"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


summary = load_script("summarize_ci")
runner = load_script("run_ci_tests")


class SummaryTests(unittest.TestCase):
    def fixture(self, name):
        return json.loads((FIXTURES / name).read_text())

    def test_success_counts_and_environment(self):
        result = summary.normalize_summary(self.fixture("summary-success.json"))
        self.assertEqual((result["passed"], result["failed"], result["skipped"]), (33, 0, 0))
        self.assertIn("18.5", str(result["environment"]))

    def test_failure_names_messages_and_skips(self):
        result = summary.normalize_summary(self.fixture("summary-failure.json"))
        self.assertEqual((result["passed"], result["failed"], result["skipped"]), (11, 2, 1))
        self.assertEqual(result["failures"][0]["name"], "CameraModelTests/testStopDuringStart()")
        self.assertIn("stale completion", result["failures"][0]["message"])
        self.assertIn("crashed", result["failures"][1]["message"])

    def test_legacy_wrappers_and_metrics(self):
        result = summary.normalize_summary(self.fixture("summary-legacy.json"))
        self.assertEqual((result["passed"], result["failed"], result["skipped"]), (3, 1, 1))
        self.assertEqual(result["failures"][0]["message"], "Stop completion timed out")

    def test_missing_and_malformed_counts_are_not_passes(self):
        for raw in ({}, {"passedTests": "unknown", "failedTests": -1, "skippedTests": None}):
            result = summary.normalize_summary(raw)
            self.assertIsNone(result["passed"])
            self.assertIsNone(result["failed"])
            self.assertIsNone(result["skipped"])

    def test_missing_bundle_keeps_failing_exit_code(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "Stress-2.status.json").write_text(json.dumps({"run": "Stress-2", "exitCode": 65}))
            markdown = summary.create_report(path)
            self.assertIn("| Stress-2 | 65 | unavailable | unavailable | unavailable | unavailable |", markdown)
            self.assertIn("Result bundle missing", markdown)

    def test_empty_artifact_directory_reports_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            markdown = summary.create_report(Path(temporary))
            self.assertIn("| LittleMoments | unavailable | unavailable | unavailable | unavailable | unavailable |", markdown)

    def test_export_failure_cannot_erase_test_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "Stress-2.xcresult").mkdir()
            (path / "Stress-2.status.json").write_text(json.dumps({"run": "Stress-2", "exitCode": 65}))
            calls = []

            def extraction(command, output, warnings, timeout=30):
                calls.append(command)
                if "summary" in command:
                    return (FIXTURES / "summary-failure.json").read_text()
                warnings.append("attachment export failed")
                return None

            with mock.patch.object(summary, "extract", side_effect=extraction):
                markdown = summary.create_report(path)
            self.assertIn("| Stress-2 | 65 | Failed | 11 | 2 | 1 |", markdown)
            self.assertIn("stale completion", markdown)
            self.assertIn("attachment export failed", markdown)
            self.assertEqual(len(calls), 3)

    def test_bad_modern_json_falls_back_to_legacy(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            bundle = path / "Stress-1.xcresult"
            bundle.mkdir()
            with mock.patch.object(summary, "extract", side_effect=["{partial", (FIXTURES / "summary-legacy.json").read_text(), None, None]):
                result = summary.collect_bundle(bundle, path)
            self.assertEqual(result["failed"], 1)
            self.assertIn("cannot parse", result["warnings"][0])

    def test_crashed_thread_is_selected_from_two_object_ips(self):
        text = summary.crash_summary(FIXTURES / "crashed-thread.ips")
        self.assertIn("SIGABRT", text)
        self.assertIn("RollingRecorder.finish()", text)
        self.assertNotIn("unrelated", text)

    def test_zipped_diagnostic_crash_stack_is_in_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            with zipfile.ZipFile(path / "device-diagnostics.zip", "w") as archive:
                archive.write(FIXTURES / "crashed-thread.ips", "logs/LittleMoments.ips")
            markdown = summary.create_report(path)
            self.assertIn("device-diagnostics.zip!logs/LittleMoments.ips", markdown)
            self.assertIn("RollingRecorder.finish()", markdown)

    def test_malformed_crash_records_do_not_discard_test_results(self):
        malformed = '{"threads": [{"triggered": true, "frames": [null]}]}'
        for zipped in (False, True):
            with self.subTest(zipped=zipped), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary)
                (path / "Stress-2.xcresult").mkdir()
                (path / "Stress-2.status.json").write_text(json.dumps({"run": "Stress-2", "exitCode": 65}))
                if zipped:
                    with zipfile.ZipFile(path / "device.zip", "w") as archive:
                        archive.writestr("broken.ips", malformed)
                else:
                    (path / "broken.ips").write_text(malformed)
                result = summary.normalize_summary(self.fixture("summary-failure.json"))
                result.update(run="Stress-2", warnings=[])
                with mock.patch.object(summary, "collect_bundle", return_value=result):
                    markdown = summary.create_report(path)
                self.assertIn("| Stress-2 | 65 | Failed | 11 | 2 | 1 |", markdown)
                self.assertIn("Could not parse crash report", markdown)
                saved = json.loads((path / "test-summary.json").read_text())
                self.assertEqual(saved["runs"]["Stress-2"]["failed"], 2)

    def test_oversized_direct_crash_keeps_original_and_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            crash = path / "large.ips"
            crash.write_text("x" * 33)
            with mock.patch.object(summary, "CRASH_SUMMARY_LIMIT", 32):
                markdown = summary.create_report(path)
            self.assertIn("Crash report exceeds 5 MiB summary limit", markdown)
            self.assertEqual(crash.read_text(), "x" * 33)
            self.assertTrue((path / "test-summary.json").exists())

    def test_timeout_keeps_partial_extraction_output_and_warning(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "summary.json"
            warnings = []
            error = summary.subprocess.TimeoutExpired("xcrun", 30, output=b"{partial", stderr=b"timed out")
            with mock.patch.object(summary.subprocess, "run", side_effect=error):
                self.assertIsNone(summary.extract(["xcrun"], path, warnings))
            self.assertEqual(path.read_text(), "{partial")
            self.assertIn("timed out", path.with_suffix(".json.stderr.log").read_text())
            self.assertTrue(warnings)

    def test_preliminary_summary_survives_interrupted_collection(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            step_summary = path / "actions-summary.md"
            def collection(artifacts, extract_bundles=True):
                if extract_bundles:
                    raise TimeoutError("diagnostics interrupted")
                return "Stress-2 exit 65; counts unavailable\n"
            with mock.patch.dict(summary.os.environ, {"GITHUB_STEP_SUMMARY": str(step_summary)}), \
                    mock.patch("sys.argv", ["summarize_ci.py", "--artifacts", str(path)]), \
                    mock.patch.object(summary, "create_report", side_effect=collection):
                with self.assertRaises(TimeoutError):
                    summary.main()
            self.assertIn("Stress-2 exit 65", step_summary.read_text())


class RunnerTests(unittest.TestCase):
    def test_first_failure_stops_stress_without_retry(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            with mock.patch.object(runner, "run_pass", side_effect=[0, 65, 0]) as run:
                result = runner.run_tests(path, path / "artifacts", "device", "stress")
            self.assertEqual(result, 65)
            self.assertEqual(run.call_count, 2)
            self.assertEqual([call.args[3] for call in run.call_args_list], ["Stress-1", "Stress-2"])
            self.assertFalse(any("UITests" in selector for selector in run.call_args.args[4]))

    def test_success_is_bounded_and_ui_runs_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            with mock.patch.object(runner, "run_pass", return_value=0) as run:
                self.assertEqual(runner.run_tests(path, path / "artifacts", "device", "stress"), 0)
                self.assertEqual(run.call_count, 3)
            with mock.patch.object(runner, "run_pass", return_value=0) as run:
                runner.run_tests(path, path / "artifacts", "device", "ordinary")
                run.assert_called_once()
                self.assertEqual(run.call_args.args[4], [])
            with self.assertRaises(ValueError):
                runner.run_tests(path, path / "artifacts", "device", "stress", iterations=4)

    def test_log_bundle_and_nonzero_exit_survive_real_subprocess(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            executable = path / "fake-xcodebuild"
            executable.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\"\necho 'injected writer failure'\nexit 65\n")
            executable.chmod(0o755)
            result = runner.run_tests(path, path / "artifacts", "device", "stress", executable=str(executable))
            self.assertEqual(result, 65)
            status = json.loads((path / "artifacts/Stress-1.status.json").read_text())
            self.assertEqual(status["exitCode"], 65)
            log = (path / "artifacts/stress-1.log").read_text()
            self.assertIn("Stress-1.xcresult", log)
            self.assertIn("injected writer failure", log)
            self.assertFalse((path / "artifacts/Stress-2.status.json").exists())

    def test_harness_stress_excludes_long_matrix(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            (path / "LittleMomentsTests").mkdir()
            source = path / "LittleMomentsTests/RollingRecorderTests.swift"
            source.write_text("func testRolloverAndRepeatedSnapshotsPreserveFrameMarkers() {}\nfunc testDelayedCompletionCannotCrossGeneration() {}\nfunc testFiveMinuteRetentionAcrossEveryWindowAndAudioMode() {}")
            selectors = runner.stress_selectors(path)
            self.assertEqual(len(selectors), 4)
            self.assertFalse(any("FiveMinute" in selector for selector in selectors))
            source.write_text("// renamed tests")
            with self.assertRaises(RuntimeError):
                runner.stress_selectors(path)


if __name__ == "__main__":
    unittest.main()
