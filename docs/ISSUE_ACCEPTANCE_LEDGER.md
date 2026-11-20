# Child issue acceptance ledger

This is the acceptance inventory for [app2 #15](https://github.com/esdu/app2/issues/15),
reviewed against the live #2–#15 issues and tested integration code head
`b48252b28e718d904c459721871097005a02dc01` on 2026-11-19.
The current native run passed; historical failed iterations are retained below.
Changes after this tested code head require their own applicable verification.
Issues #2–#15 remain open, with no comments or issue updates since the supplied snapshot (last issue update 2026-11-16).
It records scoped deliverables and remaining evidence; it
does not change GitHub issue states. #15 remains the open rollup tracker.

The dependency graph, implementation gates and shared-file merge order live in
[ISSUE_DEPENDENCIES.md](ISSUE_DEPENDENCIES.md). A source change being present does
not establish that its dependency's acceptance tests passed. The #2 native
recorder correctness gate passed at the tested integration head; its separate
physical-device acceptance remains pending.

## Evidence boundary

CI evidence rechecked read-only on 2026-11-19. Results apply to the recorded
checkout, including GitHub's PR merge commit; a focused branch pass does not
validate the combined integration. Counts below are test cases, not assertions.

### Current combined integration: passed

[Run 44572744682](https://github.com/esdu/app2/actions/runs/44572744682), attempt 1,
completed **successfully**. The recorded head is
`b48252b28e718d904c459721871097005a02dc01`; GitHub checked out PR merge `7bda4e1`
against base `a9a3961`. This result validates the combined code, including
recorder pruning, owned capture interactions, dim layout geometry,
publication-aware media validation, the twelve-case post-roll matrix and
bounded synthetic-fixture feeding, finishing and cancellation.

| Result bundle / check | Passed | Failed | Skipped | Exit / result |
| --- | --- | --- | --- | --- |
| Ordinary `LittleMoments` | **180**: 169 unit/integration + 11 UI | **0** | **0** | xcodebuild 0, Passed |
| `Stress-1` | 22 | 0 | 0 | xcodebuild 0, Passed |
| `Stress-2` | 22 | 0 | 0 | xcodebuild 0, Passed |
| `Stress-3` | 22 | 0 | 0 | xcodebuild 0, Passed |
| Python CI diagnostic fixtures | 18 | 0 | 0 | Passed |
| Source / built simulator app / archived app privacy validation | All three passed | — | — | Each manifest matches source; 1 systemUptime call covered |
| Unsigned Release iOS archive | Passed | — | — | `ARCHIVE SUCCEEDED`, 17:34:03 UTC |
| Summary, diagnostics and artifact upload | Passed | — | — | [`ios-results-1`, artifact 14557862286](https://github.com/esdu/app2/actions/runs/44572744682/artifacts/14557862286) |

The three separate stress passes each selected eleven `CameraModelTests`, nine
`MediaIntegrationTests` and two narrow recorder cases. They add **66 passed test
executions**, separate from the 180 ordinary cases. Counts are observed from
xcresult summaries and unit/UI suite footers, not inferred from source inventory.
The environment was Xcode 16.4 (16F6), iPhone SE (3rd generation), iOS Simulator
26.2 (23C54), x86_64. This is unsigned simulator/archive evidence, not a physical
iPhone run or signed distribution validation.

The full job log contains no failed test, test skip, exceeded execution allowance
or Xcode “Restarting after” message. The 120-second default and 180-second maximum
per-test allowances stayed unchanged; no failed pass was retried. The current
result includes:

- Owned interaction/touch routing, overload handling, and out-of-order
  finalization/pruning regressions.
- All seven continuous-snapshot cases, including decoded video/audio after
  publication and asynchronous track loading.
- All 42 recorder cases, including eight 300-second logical retention/audio
  variants, and all ten independent audio-boundary cases.
- Twelve post-roll endpoint methods (four windows × three tail modes) preserving
  all **24** warmup/full scenarios and their original assertions.
- All nine media cases, including new stalled-readiness timeout and cancellation
  cleanup regressions, in both ordinary execution and every stress pass.
- All three dim UI cases, including touch-only Save/Wake at largest Dynamic Type.

The DEBUG synthetic fixture now feeds each writer input through readiness
callbacks on its serial queue instead of detached polling. The existing
20-second deadline bounds both feeding and finishing, reports stage/progress,
and removes failed or cancelled output; weak callbacks and input EOF flags
settle cleanup once. This changes test infrastructure, not Release camera code.
The two new fault tests verify stalled readiness and observed cancellation with
output removal. These are bounded correctness checks, not an encoder benchmark.

These results resolve the native failures recorded below at this code head.
Physical camera/microphone delivery, hardware buttons, brightness, accessibility,
thermal/energy behavior and signed distribution remain unvalidated. Continuous
snapshot adoption and 1080p remain **no-go**, voice remains **deferred**, and the
production export/default behavior is unchanged. #15 remains open.

### Intermediate results and subsequent fixes

| Run / checkout | Observed result | Relationship to current evidence |
| --- | --- | --- |
| [44555961043](https://github.com/esdu/app2/actions/runs/44555961043), integration `5824f7f`, PR merge `06dbb5f` | **Passed**: 159 unit/integration + 11 UI = 170 ordinary; 3 × 20 stress; 18 Python; privacy and unsigned archive passed. [Artifact 14549610888](https://github.com/esdu/app2/actions/runs/44555961043/artifacts/14549610888). | Historical green before further test partitioning and fixture fixes. |
| [44556403701](https://github.com/esdu/app2/actions/runs/44556403701), PR #29 `b53defb` | **Failed**: 169 passed, 1 failed, 0 skipped. `testPostRollExactMediaEndpoints120Seconds` exceeded the unchanged 120-second allowance. All seven continuous cases and eleven UI cases passed; archive/privacy passed. | Split four per-window methods into twelve window × mode methods; all original 24 scenarios remain. |
| [44565049998](https://github.com/esdu/app2/actions/runs/44565049998), integration `d13f4d7`, PR merge `3eb066a` | **Passed**: 167 unit/integration + 11 UI = 178 ordinary; 3 × 20 stress; privacy and unsigned archive passed. [Artifact 14553571661](https://github.com/esdu/app2/actions/runs/44565049998/artifacts/14553571661). | Verifies the twelve-method split before the two fixture cleanup regressions were added. |
| [44564949735](https://github.com/esdu/app2/actions/runs/44564949735), PR #30 `271da35` | **Failed**: 170 passed, 1 failed, 0 skipped. `testLibraryPersistsAcrossReloadAndDoesNotDependOnBuffer` timed out creating its no-audio synthetic fixture before library operations (21.033 seconds). All twelve post-roll methods passed. | Replaced polling with readiness callbacks and bounded finish/cancellation cleanup; the current root and both stacks pass this case. Overload messages also occurred in passing tests, so they do not establish an infrastructure cause. |
| [44565426749](https://github.com/esdu/app2/actions/runs/44565426749), PR #29 `0d69963` | **Cancelled** after a later head was pushed; readable job logs/counts unavailable. | No passed/failed/skipped count is asserted for this cancelled run. |

### Historical combined integration and post-roll failures

| Run / checkout | Ordinary xcresult | Stress | Build / source, built, archive privacy / unsigned archive |
| --- | --- | --- | --- |
| [44121676033](https://github.com/esdu/app2/actions/runs/44121676033), integration head `083c785`, PR merge `fa6d428` | **Failed**, xcodebuild 65: **160 passed, 5 failed, 0 skipped** (165 total: unit 150 passed/4 failed; UI 10 passed/1 failed) | Skipped after ordinary failure | All passed; 18 Python diagnostic tests passed |
| [44121733610](https://github.com/esdu/app2/actions/runs/44121733610), PR #30 head `2a291e7`, PR merge `4e01032` | **Failed**, xcodebuild 65: **155 passed, 3 failed, 0 skipped** (158 total: unit 145 passed/2 failed; UI 10 passed/1 failed) | Skipped after ordinary failure | All passed; 18 Python diagnostic tests passed |

Both used Xcode 16.4 (16F6), iPhone SE (3rd generation), iOS Simulator 26.2
(23C54), x86_64. The compilation blockers from earlier iterations were resolved
at these checkouts, but neither historical run was a combined acceptance pass.

Both runs failed these exact cases:

- `CapturePressRouterTests.testHostPassesTouchesThroughAndRemovesDisabledInteraction`:
  lines 100, 102 and 106 counted two UIKit interactions where one was expected.
  Three assertions are one failing test case.
- `RollingRecorderTests.testPostRollExactMediaEndpointsWarmupAndAllRetentionWindows`:
  exceeded the **120-second per-test allowance** (the 180-second command-line
  maximum is a ceiling, not the default). Root console start/timeout:
  16:14:57.961 / 16:16:56.398 UTC; PR #30: 16:14:41.146 / 16:16:41.074 UTC.
  Native export log activity continued throughout the matrix; the logs alone
  do not prove a blocked endpoint or a completed matrix.
- `DimRecordingUITests.testAccessibleDimControlsAtLargestDynamicType`:
  line 20 `XCTAssertTrue` failed.

The combined run additionally failed
`ContinuousSnapshotTests.testAllRetentionWindowsAndConsecutiveMidSegmentSavesDecodeExactCutoffs`
(line 260: no audio `AVAssetTrack`) and
`RollingRecorderTests.testBoundedPendingWritersStopOnOverload`
(line 171: callback timeout, then `busy`; 15.092 seconds). The overload case
passed in 0.102 seconds in the PR #30 run; that does not erase the combined failure.

After the matrix timeout, Xcode logged “Restarting after unexpected exit, crash,
or test timeout; summary will include totals from previous launches” at
16:17:07 (root) and 16:16:51 (PR #30). It relaunched the test host and continued
with the nine remaining recorder cases, feedback, segment-index and thermal
suites. The last **43 passed / 0 failed** unit-suite footer describes only this
second launch. It is neither the full unit result nor a retry of the failed
matrix. The xcresult summary preserves all earlier failures and exits 65.
The repository runner launches ordinary xcodebuild once and stops stress at its
first nonzero pass; no retry-to-green masking was found, and no CI behavior was
changed during this evidence review. No readable crash reports were exported;
this is not proof that no crash occurred. Both runs retained `ios-results-1`.

Observed combined passing suites include all ten `AudioBoundaryTests`, all eight
300-second logical retention/audio variants, all seven media tests, six capture
format tests, four NV12 tests, twelve export tests, three actual-resolution tests,
eleven dim/battery tests and the preference relaunch UI case. Those partial
passes did not satisfy that historical recorder/post-roll gate; the later current
run above supplies the complete native pass. Hardware acceptance remains separate.

### Focused successful runs

Each run below completed native compilation, the stated ordinary unit/UI tests,
source and built-app privacy validation, and the **combined unsigned Release
archive plus archived-app privacy-validation step**. None is signed distribution
validation. Unit/UI logs show zero failing or skipped cases. “Not configured”
means the branch workflow had no stress step, not that stress passed.

| Scope / head / actual PR merge checkout | Run | Unit/integration passed | UI passed | Stress passed |
| --- | --- | --- | --- | --- |
| #10 post-roll `30f547c` / `12890c6` | [44573055689](https://github.com/esdu/app2/actions/runs/44573055689) | 162 (all 42 recorder and 9 media) | 11 | 3 × 22, each 0 failures / 0 skips |
| #11 continuous assessment `a0da528` / `9464435` | [44573113092](https://github.com/esdu/app2/actions/runs/44573113092) | 169 (all 7 continuous cases) | 11 | 3 × 22, each 0 failures / 0 skips |
| #2 recorder `e4f1c97` / `914ccb5` | [44556357929](https://github.com/esdu/app2/actions/runs/44556357929) | 47 (19 recorder, including pruning regression) | 5 | Not configured |
| #5 hardware routing `44f7938` / `76ca6b2` | [44555208052](https://github.com/esdu/app2/actions/runs/44555208052) | 47 (8 press-router, 3 hardware-routing) | 5 | Not configured |
| #6 dim `68f2068` / `021821a` | [44555459276](https://github.com/esdu/app2/actions/runs/44555459276) | 47 (11 dim/battery) | 8 (all 3 dim UI) | Not configured |
| #3 preferences `ff78251` / `6532d15` | [44109262588](https://github.com/esdu/app2/actions/runs/44109262588) | 36 (8 preference) | 6 (including relaunch) | Not configured |
| #4 feedback `0bb2497` / `b5bee19` | [44105073595](https://github.com/esdu/app2/actions/runs/44105073595) | 36 (8 feedback) | 5 | Not configured |
| #7 thermal `e30a947` / `0f9e8f5` | [44121215418](https://github.com/esdu/app2/actions/runs/44121215418) | 45 (9 thermal) | 8 (2 thermal, 1 preference) | Not configured |
| #8 NV12 `b32740b` / `38705f8` | [44109612845](https://github.com/esdu/app2/actions/runs/44109612845) | 56 (6 format, 4 NV12, 18 recorder) | 5 | Not configured |
| #9 export `feeef75` / `8ac5af6` | [44111017977](https://github.com/esdu/app2/actions/runs/44111017977) | 58 (5 content, 7 export, 18 recorder) | 5 | Not configured |
| #12 quality `e48adf6` / `4789a61` | [44109821028](https://github.com/esdu/app2/actions/runs/44109821028) | 49 (3 actual-resolution, 18 recorder) | 5 | Not configured |
| #13 voice assessment `b9baaf8` / `3c02bcd` | [44105310951](https://github.com/esdu/app2/actions/runs/44105310951) | 28 baseline | 5 baseline | Not configured |
| #14 CI diagnostics `415d8a4` / `3d4e52a` | [44107888519](https://github.com/esdu/app2/actions/runs/44107888519) | 28 | 5 | 3 × 14, each 0 failures / 0 skips |

The three current focused #2/#5/#6 runs completed successfully on 2026-11-19,
with no test timeout or Xcode host restart in their logs. The recorder overload
case passed in 0.115 seconds and its pruning regression in 0.046 seconds; the
focused largest-Dynamic-Type dim case passed in 41.260 seconds. The #10/#11 stacks also completed successfully on 2026-11-19. The remaining
focused runs in this table ran on 2026-11-17.

The #10 stack is based on `3188bad`; its 173 ordinary cases exclude the seven
DEBUG continuous-snapshot cases. It retained [artifact 14558441888](https://github.com/esdu/app2/actions/runs/44573055689/artifacts/14558441888),
with unsigned archive success at 17:40:52 UTC. The #11 stack is based on `30f547c`
and retained [artifact 14558635378](https://github.com/esdu/app2/actions/runs/44573113092/artifacts/14558635378).
Both current stacks also passed all eighteen Python fixtures, all three privacy
checks, unsigned archive and upload, with no timeout or test-host restart.
Root `b48252b` and #11 `a0da528` have identical app/test/project/script/workflow
contents; their documentation differs. Later documentation-only updates can be
checked against those paths without claiming a new native run.

The #14 run also passed 18 Python fixture tests. Its xcresult summary explicitly
reports ordinary 33/0/0 and Stress-1, Stress-2, Stress-3 each 14/0/0. This
baseline stress result does not validate the later integrated recorder selectors.
The voice assessment run validates the unchanged baseline app, not runtime speech.

Earlier integration runs remain failed/cancelled history:
[44104753849](https://github.com/esdu/app2/actions/runs/44104753849) at `2575db6`
and [44107903119](https://github.com/esdu/app2/actions/runs/44107903119) at `38a5f3d`
failed dim deinitializer actor-isolation compilation;
[44106794217](https://github.com/esdu/app2/actions/runs/44106794217) at `9da97e1`
was cancelled. Earlier preference run
[44104742324](https://github.com/esdu/app2/actions/runs/44104742324) failed its
relaunch UI query, superseded by the focused pass above. Earlier recorder run
[44104835233](https://github.com/esdu/app2/actions/runs/44104835233) failed compilation;
passing later runs do not erase those historical failures.

No physical iPhone run, hardware-button delivery, brightness restoration,
haptic/VoiceOver device check, thermal/energy measurement or signed distribution
validation is claimed. [PHYSICAL_TESTING.md](PHYSICAL_TESTING.md) remains pending.
Production Off still uses the freezing retrospective path. Highest-quality export
remains the default, 1080p is no-go, continuous snapshots remain an experiment,
and voice remains deferred.

## Scoped status and remaining acceptance

“Pending native” means implementation and assertions are present for review, but
the required Apple-platform result is absent. It does not mean ready for closure.
Assessment completion is separate from permission to enable a runtime feature.
Focused PR links identify review scope, not a passed CI run or merged change.

| Issue | Integrated implementation or assessment | Native/software evidence and remaining acceptance | Physical or other acceptance still needed | Honest closure status |
| --- | --- | --- | --- | --- |
| [#2](https://github.com/esdu/app2/issues/2) · [PR #19](https://github.com/esdu/app2/pull/19) | Production `RollingRecorder` ingestion seam, deterministic timestamped A/V source, rotation/leases/library tests and diagnostics; independent 10 ms PCM boundary/leading/lagging-delivery coverage. [Harness note](ISSUE_2_RECORDER_HARNESS.md). | Native acceptance passed at `b48252b`: 42 recorder cases, ten audio-boundary cases, eleven model cases and nine media cases, within 169 unit/integration + eleven UI and three twenty-two-case stress passes. This includes all eight 300-second logical retention/audio variants, exact decoded endpoints/audio markers, rollover/warmup/repeated saves, leases, lifecycle/failure/watchdog and cleanup. Focused `e4f1c97` separately passed 47 unit/integration + five UI, including out-of-order finalization/pruning and overload cases. Preserve result bundles and rerun applicable regressions after later code changes. | Real camera cadence/orientation, microphone negotiation, interruption/protected-data behavior and sustained pressure/storage runs. Low-resolution accelerated fixtures establish no device performance. | Native recorder correctness passed; physical acceptance pending. Keep open. |
| [#3](https://github.com/esdu/app2/issues/3) · [PR #17](https://github.com/esdu/app2/pull/17) | Typed, versioned, tolerant preference store; guarded model updates; disposable test domains; CA92.1 declaration. [Preferences note](ISSUE_3_PREFERENCES.md). | Focused `ff78251` passed 36 unit/integration + six UI cases, including relaunch; packaging/privacy passed. Current combined `b48252b` also passed all nine preference cases and relaunch UI, with the full integrated regression and source/built/archive privacy green. Native stopped-relaunch/persistence scope is verified at that head; later code changes need applicable regression. | No feature-specific hardware benchmark required; retain the shared release/privacy gates. | Scoped native preference acceptance and integrated regression passed. No GitHub closure is asserted. |
| [#4](https://github.com/esdu/app2/issues/4) · [PR #21](https://github.com/esdu/app2/pull/21) | One guarded save path, commit-based nonmodal status, injectable haptics/announcements and replacement-safe timeout. [Feedback note](ISSUE_4_SAVE_FEEDBACK.md). | Focused `0bb2497` passed 36 unit/integration (eight feedback) + five UI cases and packaging/privacy. Current combined `b48252b` passed all ten feedback cases, baseline UI, full integrated regression and packaging/privacy. | Physical haptic delivery and VoiceOver announcements/focus, accessible text and navigation behavior. | Native feedback and integrated regression passed; physical accessibility/haptic evidence pending. Keep open. |
| [#5](https://github.com/esdu/app2/issues/5) · [PR #25](https://github.com/esdu/app2/pull/25) | Public `AVCaptureEventInteraction` adapter, iOS 17.2 availability gate, iOS 17.0–17.1 onscreen fallback, guarded release routing and stale callback rejection. [Button note](ISSUE_5_VOLUME_BUTTONS.md). | Focused `44f7938` passed 47 unit/integration + five UI cases, including eight press-router and three hardware-routing cases; packaging/privacy passed. Current combined `b48252b` passed those suites and baseline onscreen UI with deployment target 17.0. Owned interaction accounting resolves the historical count failure. Synthetic callbacks do not exercise hardware delivery. | Both buttons, one clip per press/hold, rapid/save-finalization presses, dim operation, navigation/interruption cleanup, normal volume outside eligible capture and minimum-OS fallback. | Native routing/onscreen acceptance passed; physical validation is required before production hardware support is claimed. Keep open. |
| [#6](https://github.com/esdu/app2/issues/6) · [PR #24](https://github.com/esdu/app2/pull/24) | Explicit dim view with touch Save/Wake, scene-specific brightness ownership/restoration, battery status and accessible post-roll countdown. The current geometry helper resolves the historical largest-Dynamic-Type UI failure; all dim suites passed at the tested combined head. [Dim/battery note](ISSUE_6_DIM_BATTERY.md). | Focused `68f2068` passed 47 unit/integration + eight UI cases, including eleven dim/battery and all three dim UI cases. Current combined `b48252b` also passed those suites, including largest Dynamic Type, touch-only Save/Wake, lifecycle and observer cleanup. Native build, integrated regression and packaging/privacy passed. | Actual brightness restoration across wake/stop/library/call/Home/lock and termination/relaunch; Control Center changes; charging updates; VoiceOver/XXXL/small-screen operation at dim brightness. No energy-saving claim without measurement. | Native dim/battery/layout acceptance passed; physical brightness/accessibility acceptance pending. Keep open. |
| [#7](https://github.com/esdu/app2/issues/7) · [PR #27](https://github.com/esdu/app2/pull/27) | Serious warning, critical pause/start block, explicit restart after cooling, no silent quality change. [Thermal note](ISSUE_7_THERMAL.md). | Focused thermal head passed 45 unit/integration + eight UI cases, including nine thermal and two thermal UI cases, with packaging/privacy passed. Current combined `b48252b` passed thermal, recorder, cancellation and feedback suites and the native #2 correctness gate. Simulator injection verifies stale notifications/start races, saved-file/lease preservation, exactly-once stops and explicit restart policy at that head. | Sustained physical soak with timestamped thermal states, audio/window variants, pending saves, decoded outputs and recovery. Simulator injection validates policy only. | Native thermal policy/UI and integrated recorder gate passed; physical soak pending. Keep open. |
| [#8](https://github.com/esdu/app2/issues/8) · [PR #26](https://github.com/esdu/app2/pull/26) | Supported NV12 preference with BGRA fallback, explicit supported 30 fps selection/readback, sample validation and configuration/drop diagnostics. [NV12 note](ISSUE_8_NV12_BASELINE.md). | Focused NV12 head passed 56 unit/integration + five UI cases, including six format, four NV12 and eighteen recorder cases, with packaging/privacy passed. Current combined `b48252b` passed all format/NV12 cases and the native #2 gate. The bounded synthetic fixtures cover both NV12 ranges/audio variants, color, frame IDs/PTS, portrait metadata, fallback/errors and fresh-generation state. | Front/rear actual formats/cadence/drops, physical portrait/color/A/V checks and matched BGRA/NV12 CPU/memory/energy/thermal/long-session measurements. Synthetic portrait input does not test sensor rotation. | Native correctness and integrated gate passed; device evidence pending. No measured performance gain. Keep open. |
| [#9](https://github.com/esdu/app2/issues/9) · [PR #28](https://github.com/esdu/app2/pull/28) | Internal `.evaluatePassthrough` candidate with compatibility check, narrow fallback and cleanup. Production `ClipComposer()` remains `.highestQuality` MP4. [Export note](ISSUE_9_EXPORT_EVALUATION.md). | Focused export head passed 58 unit/integration + five UI cases, including seven export and five content cases, with packaging/privacy passed. Current combined `b48252b` passed all twelve export/content cases and the native #2/media gate. This verifies bounded synthetic decoded endpoints/non-keyframe trims, A/V joins/gaps, orientation/windows, fallback, cancellation/failure and lease assertions; retain actual attempt sequence, bytes and timing attachments. | Early/full/repeated-save iPhone comparison, encoder pressure/drops/thermal/energy, physical front/rear playback, Photos/share consumers, reload/deletion. | Native export evaluation and integrated regression passed; physical measurements pending. Default unchanged; no adoption or issue closure claimed. |
| [#10](https://github.com/esdu/app2/issues/10) · [PR #30](https://github.com/esdu/app2/pull/30) | Integrated bounded Off/5/10-second post-roll with fixed media-time intervals, immediate/future leases, nonfreezing positive-tail collection, progress and shorter/error interruption outcomes; independent audio-boundary cleanup. [Post-roll note](ISSUE_10_POST_ROLL.md). | Current combined `b48252b` passed all 42 recorder cases, ten audio-boundary cases, preference/model/feedback and dim UI suites. All 24 endpoint/warmup/tail/window scenarios passed as twelve window × tail-mode XCTest methods under the unchanged 120-second default allowance, alongside retained pre-trigger files, repeated-save bounds, partial/error reporting, duplicate taps, cancellation/restart, interruption/stall/low-disk and cleanup assertions. The earlier timeout is retained in historical evidence above; the current complete native matrix passed. | Physical capture/storage/PCM-packet/lifecycle validation after native correctness; real work/file bounds, thermal and VoiceOver behavior remain pending. | Integrated native post-roll acceptance passed; physical acceptance pending. Keep open. Off remains the original retrospective behavior. |
| [#11](https://github.com/esdu/app2/issues/11) · [PR #29](https://github.com/esdu/app2/pull/29) | Integrated DEBUG-only alternative continuous segmented-MOV snapshot experiment and comparison suite, using the #10 fixed-interval seam. [Continuous snapshot note](ISSUE_11_CONTINUOUS_SNAPSHOT.md). This is not an fMP4 writer; production Off is unchanged. | Current combined `b48252b` passed all seven `ContinuousSnapshotTests`, including all-window/consecutive-save decoded video/audio content after publication and asynchronous track loading. Native #2/#9/#10 suites passed. The assessment remains no-go: aggregate capture-plus-export hard reservation/growth bounds are unresolved; sampled small-fixture byte census does not establish them. | Matched iPhone baseline/prototype continuity, latency, memory, actual peak disk use and energy/thermal measurements; review migration only if correctness, resource bounds and measured benefits justify adoption. | Native prototype comparison passed; aggregate budget and physical acceptance pending. Keep open; **no-go for production adoption**. |
| [#12](https://github.com/esdu/app2/issues/12) · [PR #22](https://github.com/esdu/app2/pull/22) | [1080p30 no-go assessment](ISSUE_12_QUALITY_FEASIBILITY.md), resource calculator and three [actual-resolution harness tests](ISSUE_12_QUALITY_HARNESS.md): portrait 720×1280/1080×1920, early/rollover/full-15s trimming and stopped-generation isolation. No runtime preset/settings added; 720p retained, 4K/60 deferred. | All three `QualityResolutionRecorderTests` passed in focused run 44109821028 (49 unit/integration + five UI, packaging/privacy passed) and current combined `b48252b`; native #2/#7/#8 gates also passed. The full-size fixture remains **2 fps, 112 source frames and one full 15s window**, not all four full-resolution windows or sustained 30 fps. Its frame ID/PTS, PCM and orientation assertions passed for that bounded fixture. Quality preference/capability/fallback tests and measured/enforced peak working-set/retention analysis remain future gates; calculator arithmetic is not an encoder bound. | Exact device/OS/build/camera capability table, sample/export dimensions/cadence/bitrate and sustained longest-window audio on/off, repeated-save, low-storage/system-pressure/quality measurements. | No-go decision and bounded native coverage complete; **full issue acceptance incomplete**. Broader full-resolution and physical requirements remain open; no validated 1080p bitrate or support claim. |
| [#13](https://github.com/esdu/app2/issues/13) · [PR #23](https://github.com/esdu/app2/pull/23) | [Voice feasibility note](ISSUE_13_VOICE_FEASIBILITY.md) recommends **defer** and supplies capability/permission matrix, lifecycle/stale-callback design, failure/privacy language, hardware-button comparison and scoped test/evaluation plan. No runtime speech, permission or production start-path change. | Assessment is documentation-only and its bounded deliverable is complete. Any later implementation must separately execute the specified fake/UI/privacy tests and reuse #2/#3/#4. | Every device/OS/locale capability, recognition reliability and energy result is unvalidated; a later opt-in prototype needs the specified corpus and matched hardware runs. Hardware was conditional for this assessment. | Eligible for closure **as a deferred assessment only**. This neither completes a voice feature nor authorizes enabling recognition. No GitHub closure is asserted here. |
| [#14](https://github.com/esdu/app2/issues/14) · [PR #20](https://github.com/esdu/app2/pull/20) | Bounded stop-on-first-failure stress selection, independent run evidence, robust summaries/crash extraction and retained artifacts. [CI note](ISSUE_14_CI_DIAGNOSTICS.md). Local Python fixture tests are reported in that note. | Current combined `b48252b` passed 180 ordinary cases, three separate twenty-two-case stress passes, eighteen Python fixtures and source/built/archive privacy plus unsigned archive. Summaries reported exact 180/0/0 and 22/0/0 × 3, with successful artifact upload and no host restart. Historical failed integration/PR #30 runs retained earlier failures across Xcode restart and exited 65; their stress step was skipped. Further injected crash/missing-bundle/extraction-failure Actions acceptance remains separate from fixture coverage and the observed real timeout/failure behavior. | No new hardware benchmark required; signed distribution remains separate. | Ordinary/stress/archive execution and real failure preservation verified; remaining injected failure-path acceptance pending. Keep open. |
| [#15](https://github.com/esdu/app2/issues/15) | Handoff/rollup tracker, dependency graph and this acceptance ledger. [Graph PR #16](https://github.com/esdu/app2/pull/16); [integration PR #18](https://github.com/esdu/app2/pull/18). | Tested combined code head `b48252b` and its green native CI/result artifact are linked above, alongside scoped focused proof and historical failures. Continue child review/acceptance against its own scope; preserve physical, resource-budget, broader quality and failure-injection gates and rerun applicable checks after code changes. | Retain explicit device and signing gates across children. | **Tracker remains open.** A green combined native run does not complete every child or the rollup. |

## Evidence needed for the next status update

1. Preserve the verified `b48252b` native run and result bundles. For later code
   changes, record the new head and applicable ordinary/stress/privacy/archive
   results; documentation-only follow-ups do not extend this code result to
   future runtime changes. Retain failed iterations as failures.
2. Retain the combined native #10/#11 evidence and the separately observed
   focused-stack results above. Their shared
   fixed-interval/pinning contract must preserve bounded storage/work, protected
   atomic publication, lease lifetime and explicit restart. Resolve #11's aggregate
   export/capture budget before adoption; the prototype does not replace the
   production Off recorder path.
3. Attach physical evidence to the relevant child checklists, with device/iOS/build,
   conditions, duration, observed outputs and pass/fail. Keep unexecuted rows pending.
   Do not infer hardware results from simulator success or capability enumeration.
4. Preserve the decisions: highest-quality export remains the production default;
   1080p30 is no-go pending evidence; 4K/60 remain deferred; voice remains deferred
   with no runtime speech. Signed archive/App Store validation is a later release
   gate and has not been performed.
