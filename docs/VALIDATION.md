# Validation evidence

## Verified automated results

[Successful GitHub Actions run](https://github.com/esdu/app2/actions/runs/43955515633) validates code commit `87bf16a26f6bcd5afea83464e036499eae8da447` on a standard GitHub-hosted `macos-15-intel` runner using Xcode 16.4 and the iOS 18.5 Simulator.

| Check | Observed result |
| --- | --- |
| Dependency resolution | Passed; no third-party app dependencies |
| Application and both test targets | Compiled successfully without simulator code signing |
| Camera model tests | 7 passed, 0 failed |
| Media integration tests | 7 passed, 0 failed |
| Buffer policy / timestamp / watchdog tests | 14 passed, 0 failed |
| All unit/integration tests | **28 passed, 0 failed** |
| XCUITest | **5 passed, 0 failed** |
| Source uptime privacy declaration | Passed; reason `35F9.1` covers all three calls |
| Built simulator app privacy manifest | Passed; matches reviewed source |
| Unsigned generic iOS Release archive | Built successfully |
| Archived app privacy manifest | Passed; includes System Boot Time reason `35F9.1` and matches source |
| Workflow conclusion | **Success** |
| Diagnostics and artifact upload | Success |

[Download the run's `ios-results-1` artifact](https://github.com/esdu/app2/actions/runs/43955515633/artifacts/14272258787). It contains build and test result bundles, build/test logs, UI screenshot and accessibility-hierarchy attachments, simulator logs, a final screen capture, `Archive.xcresult`, `Archived-PrivacyInfo.xcprivacy`, and the three privacy validation logs. GitHub retains this artifact for 14 days. The README badge links to the workflow for newer runs.

The seven media integration tests generate real H.264/AAC data, exercise the production segment writer, trim and join segments with the production composer, decode exported video with AVAssetReader, verify A/V track timing, reload saved clips after source-buffer deletion, and check cleanup/deletion. UI tests use an explicit DEBUG-only synthetic camera and the real composition/library implementation. All test cases remain enabled; encoder deadlines and XCTest timeouts turn stalls into failures.

Earlier media export and synthetic A/V interleaving failures were fixed and the same failing cases passed in both the baseline run and the final run. The final run also verifies that a restart waits for the preceding stop operation to complete.

[Issue #1](https://github.com/esdu/app2/issues/1) is verified against the actual archived resource: the downloaded `Archived-PrivacyInfo.xcprivacy` contains all three API categories, including System Boot Time with reason `35F9.1`. The source validator also rejects the original manifest, reproducing the omission. This unsigned packaging check does not perform signed distribution validation or an App Store submission. See [privacy validation](PRIVACY_VALIDATION.md) for the signing-dependent release step.

Documentation-only evidence updates after the tested commit do not change app code, tests, project configuration, or the workflow.

## Not hardware validation

- The development workspace is Linux; the iOS build and tests ran on GitHub's macOS runner.
- Physical iPhone camera/microphone capture, thermal/storage soak, interruption timing, and physical accessibility acceptance are **not executed**. Simulator success does not prove them.
- Normal app launches use the production AVFoundation camera, including normal simulator launches. Synthetic data is selected only by the UI-test launch argument in DEBUG and is excluded from Release builds.
- Complete the [physical iPhone checklist](PHYSICAL_TESTING.md) before release. Known MVP limits include foreground-only capture, portrait 720p, a brief intake pause while a save finalizes segments, and sampled disk-safety checks with bounded in-flight work.
