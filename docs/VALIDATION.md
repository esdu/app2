# Validation evidence

## Verified automated results

[Successful GitHub Actions run](https://github.com/esdu/app2/actions/runs/43925110201) validates code commit `9318fa6d01facead1fb9474dc63bd275924109f2` on a standard GitHub-hosted `macos-15-intel` runner using Xcode 16.4 and the iOS 18.5 Simulator.

| Check | Observed result |
| --- | --- |
| Dependency resolution | Passed; no third-party app dependencies |
| Application and both test targets | Compiled successfully without simulator code signing |
| Camera model tests | 7 passed, 0 failed |
| Media integration tests | 7 passed, 0 failed |
| Buffer policy / timestamp / watchdog tests | 14 passed, 0 failed |
| All unit/integration tests | **28 passed, 0 failed** |
| XCUITest | **5 passed, 0 failed** |
| Workflow conclusion | **Success** |
| Diagnostics and artifact upload | Success |

[Download the run's `ios-results-1` artifact](https://github.com/esdu/app2/actions/runs/43925110201/artifacts/14256917108). It contains build and test result bundles, build/test logs, UI screenshot and accessibility-hierarchy attachments, simulator logs, and a final screen capture. GitHub retains this artifact for 14 days. The README badge links to the workflow for newer runs.

The seven media integration tests generate real H.264/AAC data, exercise the production segment writer, trim and join segments with the production composer, decode exported video with AVAssetReader, verify A/V track timing, reload saved clips after source-buffer deletion, and check cleanup/deletion. UI tests use an explicit DEBUG-only synthetic camera and the real composition/library implementation. All test cases remain enabled; encoder deadlines and XCTest timeouts turn stalls into failures.

Earlier media export and synthetic A/V interleaving failures were fixed and the same failing cases passed in both the baseline run and the final run. The final run also verifies that a restart waits for the preceding stop operation to complete.

Documentation-only evidence updates after the tested commit do not change app code, tests, project configuration, or the workflow.

## Not hardware validation

- The development workspace is Linux; the iOS build and tests ran on GitHub's macOS runner.
- Physical iPhone camera/microphone capture, thermal/storage soak, interruption timing, and physical accessibility acceptance are **not executed**. Simulator success does not prove them.
- Normal app launches use the production AVFoundation camera, including normal simulator launches. Synthetic data is selected only by the UI-test launch argument in DEBUG and is excluded from Release builds.
- Complete the [physical iPhone checklist](PHYSICAL_TESTING.md) before release. Known MVP limits include foreground-only capture, portrait 720p, a brief intake pause while a save finalizes segments, and sampled disk-safety checks with bounded in-flight work.
