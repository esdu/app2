# Validation evidence

## Verified integration

[GitHub Actions run 44572744682](https://github.com/esdu/app2/actions/runs/44572744682), attempt 1, validated code commit `b48252b28e718d904c459721871097005a02dc01` through PR merge checkout `7bda4e1` on 2026-11-19. The standard `macos-15-intel` runner selected Xcode 16.4 (16F6) and an iPhone SE (3rd generation), iOS 26.2 Simulator (23C54), x86_64. This is the observed simulator environment, not a physical-device result.

| Check | Observed result |
| --- | --- |
| Application and both test targets | Compiled without simulator signing |
| Ordinary unit/integration suite | **169 passed, 0 failed, 0 skipped** |
| UI suite | **11 passed, 0 failed, 0 skipped** |
| Ordinary total | **180 passed, 0 failed, 0 skipped** |
| Focused stress | **3 passes × 22 tests**, each 0 failed/0 skipped; all exits 0 |
| Portable CI-tooling tests | **18 passed** in this run |
| Source privacy validation | Passed; one explicit uptime call covered by `35F9.1` |
| Built simulator privacy manifest | Passed; matches reviewed source |
| Unsigned generic-device Release archive | Passed |
| Archived privacy manifest | Passed; matches source, including all four API categories |
| Per-run summaries, diagnostics and upload | Passed; no test-host restart or execution timeout |
| Workflow conclusion | **Success** |

[Artifact `ios-results-1` (14557862286)](https://github.com/esdu/app2/actions/runs/44572744682/artifacts/14557862286) was uploaded successfully. It contains ordinary and separate stress `.xcresult` bundles, status JSON/logs, extracted attachments and summaries, build/archive evidence, `Archived-PrivacyInfo.xcprivacy`, privacy logs, simulator logs and screenshots. GitHub retains artifacts for 14 days.

The production recorder tests cover all four 300-second logical retention windows with audio on/off, decoded frame/tone identity, boundary trims, leases, deadlines, generation isolation and failure cleanup. Additional suites exercise NV12 colors, actual 720p/1080p portrait dimensions, post-roll endpoints, internal export/snapshot comparisons, preference persistence, guarded input, brightness/battery and thermal policy. Accelerated synthetic fixtures establish their stated correctness assertions; they are not sustained 30 fps, device-energy or hardware benchmarks.

The twelve post-roll endpoint cases preserve all 24 original scenarios (four retention windows × Off/5/10 tails × warmup/full state) without increasing the 120-second default/180-second maximum per-test limits. Earlier grouped cases exceeded the default allowance; the scenario assertions remain intact. Former hardware ownership, frozen-snapshot pruning, overload, publication and largest-text failures passed in this run. The full suite is followed only by the narrow stress selection; failures are never retried to obtain green.

The DEBUG synthetic movie fixture now feeds each encoder input from its readiness callback on a per-fixture serial queue. The unchanged 20-second bound includes finalization, and cancellation settles once, cancels writing and removes partial output. New forced-readiness-timeout and cancellation cleanup cases passed in the ordinary suite and each stress pass. This addresses a recorded fixture timeout before library operations; it does not establish physical encoder performance.

Focused review stacks also passed: [post-roll PR #30, run 44573055689](https://github.com/esdu/app2/actions/runs/44573055689), head `30f547c`, merge `12890c6`, passed 162 unit/integration + 11 UI = **173 ordinary**, plus **3 × 22 stress**; [continuous assessment PR #29, run 44573113092](https://github.com/esdu/app2/actions/runs/44573113092), head `a0da528`, merge `9464435`, passed **180 ordinary + 3 × 22 stress**. Both reported zero failures/skips and passed 18 Python tests, all privacy checks, unsigned archive and artifact upload. The PR #29 app/test/project/script/workflow contents match the tested combined head; PR #30 excludes the seven prototype cases.

Failed iterations and exact focused-branch evidence remain in the [acceptance ledger](ISSUE_ACCEPTANCE_LEDGER.md). The earlier [87bf16a baseline run](https://github.com/esdu/app2/actions/runs/43955515633) passed 28 unit/integration and five UI tests and reproduced/fixed privacy issue #1; it is historical evidence, not the current integration result. Five offline storage-calculator self-tests also pass locally; their assumptions are not measured encoder bounds.

Documentation-only updates after the tested commit do not change app code, tests, project configuration, scripts or workflows. Compare those paths with `b48252b` when reviewing a later documentation head.

## Remaining acceptance

- Physical front/rear camera and microphone behavior, supported cadence/color/orientation, buttons, brightness, VoiceOver/haptics, interruptions, storage/thermal/energy soak and lowest supported OS require the [iPhone checklist](PHYSICAL_TESTING.md).
- Normal launches use production AVFoundation. UI tests opt into an isolated DEBUG synthetic camera; Release excludes that fixture and the continuous-snapshot experiment.
- Highest-quality export and the established recorder remain defaults. Passthrough and continuous snapshots remain internal evaluations; 1080p30 and voice remain no-go/deferred pending their stated gates.
- Signed distribution archive/Organizer/App Store validation has not been performed. See [privacy validation](PRIVACY_VALIDATION.md).
