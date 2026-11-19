# Child issue acceptance ledger

This is the acceptance inventory for [app2 #15](https://github.com/esdu/app2/issues/15),
reviewed against the live #2–#15 issues and integration commit `083c785` on
2026-11-19. The native results below ran on 2026-11-17; later local source
corrections require a new native result. Issues #2–#15 remain open, with no
comments or issue updates since the supplied snapshot (last issue update 2026-11-16).
It records scoped deliverables and remaining evidence; it
does not change GitHub issue states. #15 remains the open rollup tracker.

The dependency graph, implementation gates and shared-file merge order live in
[ISSUE_DEPENDENCIES.md](ISSUE_DEPENDENCIES.md). A source change being present does
not establish that its dependency's acceptance tests passed. In particular, the
#2 recorder correctness gate is still awaiting a successful native result.

## Evidence boundary

CI evidence rechecked read-only on 2026-11-19. Results apply to the recorded
checkout, including GitHub's PR merge commit; a focused branch pass does not
validate the combined integration. Counts below are test cases, not assertions.

### Combined integration and post-roll failures

| Run / checkout | Ordinary xcresult | Stress | Build / source, built, archive privacy / unsigned archive |
| --- | --- | --- | --- |
| [44121676033](https://github.com/esdu/app2/actions/runs/44121676033), integration head `083c785`, PR merge `fa6d428` | **Failed**, xcodebuild 65: **160 passed, 5 failed, 0 skipped** (165 total: unit 150 passed/4 failed; UI 10 passed/1 failed) | Skipped after ordinary failure | All passed; 18 Python diagnostic tests passed |
| [44121733610](https://github.com/esdu/app2/actions/runs/44121733610), PR #30 head `2a291e7`, PR merge `4e01032` | **Failed**, xcodebuild 65: **155 passed, 3 failed, 0 skipped** (158 total: unit 145 passed/2 failed; UI 10 passed/1 failed) | Skipped after ordinary failure | All passed; 18 Python diagnostic tests passed |

Both used Xcode 16.4 (16F6), iPhone SE (3rd generation), iOS Simulator 26.2
(23C54), x86_64. The compilation blockers from earlier iterations are resolved
at these checkouts, but neither run is a combined acceptance pass.

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
eleven dim/battery tests and the preference relaunch UI case. These partial
passes do not satisfy the failing recorder/post-roll gate or hardware acceptance.

### Focused successful runs

Each run below completed native compilation, the stated ordinary unit/UI tests,
source and built-app privacy validation, and the **combined unsigned Release
archive plus archived-app privacy-validation step**. None is signed distribution
validation. Unit/UI logs show zero failing or skipped cases. “Not configured”
means the branch workflow had no stress step, not that stress passed.

| Scope / head / actual PR merge checkout | Run | Unit/integration passed | UI passed | Stress passed |
| --- | --- | --- | --- | --- |
| #3 preferences `ff78251` / `6532d15` | [44109262588](https://github.com/esdu/app2/actions/runs/44109262588) | 36 (8 preference) | 6 (including relaunch) | Not configured |
| #4 feedback `0bb2497` / `b5bee19` | [44105073595](https://github.com/esdu/app2/actions/runs/44105073595) | 36 (8 feedback) | 5 | Not configured |
| #7 thermal `e30a947` / `0f9e8f5` | [44121215418](https://github.com/esdu/app2/actions/runs/44121215418) | 45 (9 thermal) | 8 (2 thermal, 1 preference) | Not configured |
| #8 NV12 `b32740b` / `38705f8` | [44109612845](https://github.com/esdu/app2/actions/runs/44109612845) | 56 (6 format, 4 NV12, 18 recorder) | 5 | Not configured |
| #9 export `feeef75` / `8ac5af6` | [44111017977](https://github.com/esdu/app2/actions/runs/44111017977) | 58 (5 content, 7 export, 18 recorder) | 5 | Not configured |
| #12 quality `e48adf6` / `4789a61` | [44109821028](https://github.com/esdu/app2/actions/runs/44109821028) | 49 (3 actual-resolution, 18 recorder) | 5 | Not configured |
| #13 voice assessment `b9baaf8` / `3c02bcd` | [44105310951](https://github.com/esdu/app2/actions/runs/44105310951) | 28 baseline | 5 baseline | Not configured |
| #14 CI diagnostics `415d8a4` / `3d4e52a` | [44107888519](https://github.com/esdu/app2/actions/runs/44107888519) | 28 | 5 | 3 × 14, each 0 failures / 0 skips |

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
passing retention cases in later runs do not erase the current recorder failures.

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

| Issue | Integrated implementation or assessment | Native/software acceptance still needed | Physical or other acceptance still needed | Honest closure status |
| --- | --- | --- | --- | --- |
| [#2](https://github.com/esdu/app2/issues/2) · [PR #19](https://github.com/esdu/app2/pull/19) | Production `RollingRecorder` ingestion seam, deterministic timestamped A/V source, rotation/leases/library tests and diagnostics; independent 10 ms PCM boundary/leading/lagging-delivery coverage. [Harness note](ISSUE_2_RECORDER_HARNESS.md). | Later native compilation and all eight retention/audio cases plus ten audio-boundary tests passed in the combined run, but overload callback handling failed and the post-roll matrix timed out (see evidence above). Obtain a green final-head result for `RollingRecorderTests`, `CameraModelTests` and media tests: all four 300-second logical retention windows with audio on/off, decoded endpoints/counts/audio markers, rollover/warmup/repeated saves, lifecycle/failure/watchdog and cleanup. Retain failed media/timing evidence. All ten added `AudioBoundaryTests` for session-start PCM trimming and independent leading/lagging packet delivery across rollovers passed in the combined run; later changes still need regression. | Real camera cadence/orientation, microphone negotiation, interruption/protected-data behavior and sustained pressure/storage runs. Low-resolution accelerated fixtures establish no device performance. | Implementation present; acceptance pending native and separate device checks. Keep open. |
| [#3](https://github.com/esdu/app2/issues/3) · [PR #17](https://github.com/esdu/app2/pull/17) | Typed, versioned, tolerant preference store; guarded model updates; disposable test domains; CA92.1 declaration. [Preferences note](ISSUE_3_PREFERENCES.md). | Focused `ff78251` passed 36 unit/integration and six UI tests, including relaunch; source/built/archive privacy and unsigned archive passed. The combined run also passed nine preference tests and relaunch UI, but the combined suite failed elsewhere. Obtain a green final-head regression. Verify stopped relaunch and no permission/capture request; validate source/built/archive manifests with the new declaration. | No feature-specific hardware benchmark required; retain the shared release/privacy gates. | Focused native relaunch acceptance passed; final integrated regression pending. Keep open until scoped acceptance passes. |
| [#4](https://github.com/esdu/app2/issues/4) · [PR #21](https://github.com/esdu/app2/pull/21) | One guarded save path, commit-based nonmodal status, injectable haptics/announcements and replacement-safe timeout. [Feedback note](ISSUE_4_SAVE_FEEDBACK.md). | Focused head `0bb2497` passed 36 unit/integration tests (including eight `SaveFeedbackTests`), five UI tests and built/archive privacy (see run above). Run final integrated regression to cover the later recorder/post-roll/quality changes. | Physical haptic delivery and VoiceOver announcements/focus, accessible text and navigation behavior. | Focused native checks passed; final integrated regression and physical accessibility evidence pending. Keep open. |
| [#5](https://github.com/esdu/app2/issues/5) · [PR #25](https://github.com/esdu/app2/pull/25) | Public `AVCaptureEventInteraction` adapter, iOS 17.2 availability gate, iOS 17.0–17.1 onscreen fallback, guarded release routing and stale callback rejection. [Button note](ISSUE_5_VOLUME_BUTTONS.md). | Combined native build passed with deployment target 17.0; three hardware-routing cases and baseline UI passed, but the interaction-count test failed three assertions (see evidence). Correct it and obtain a green final-head result for `CapturePressRouterTests`, `HardwareSaveRoutingTests` and onscreen UI regressions. Synthetic callback tests do not exercise hardware delivery. | Both buttons, one clip per press/hold, rapid/save-finalization presses, dim operation, navigation/interruption cleanup, normal volume outside eligible capture and minimum-OS fallback. | Implementation present; physical validation explicitly required before production support is claimed. Keep open. |
| [#6](https://github.com/esdu/app2/issues/6) · [PR #24](https://github.com/esdu/app2/pull/24) | Explicit dim view with touch Save/Wake, scene-specific brightness ownership/restoration, battery status and accessible post-roll countdown. Earlier actor-isolation compilation failures are resolved in run 44121676033; eleven dim/battery cases passed, while largest-Dynamic-Type UI failed. [Dim/battery note](ISSUE_6_DIM_BATTERY.md). | Resolve the largest-Dynamic-Type UI failure and rerun final-head `DimBatteryTests` and `DimRecordingUITests`: all exits, external brightness changes, observer cleanup, background/no auto-resume, large text and touch-only save. | Actual brightness restoration across wake/stop/library/call/Home/lock and termination/relaunch; Control Center changes; charging updates; VoiceOver/XXXL/small-screen operation at dim brightness. No energy-saving claim without measurement. | Implementation present; native and hardware acceptance pending. Keep open. |
| [#7](https://github.com/esdu/app2/issues/7) · [PR #27](https://github.com/esdu/app2/pull/27) | Serious warning, critical pause/start block, explicit restart after cooling, no silent quality change. [Thermal note](ISSUE_7_THERMAL.md). | Focused thermal head passed 45 unit/integration and eight UI tests, including nine thermal and two thermal UI cases; packaging/privacy passed. Combined thermal suites also passed. Obtain a green final integrated recorder, cancellation and feedback regression. Verify stale notifications/start races, saved-file/lease preservation and exactly-once stops; satisfy #2 correctness gate. | Sustained physical soak with timestamped thermal states, audio/window variants, pending saves, decoded outputs and recovery. Simulator injection validates policy only. | Focused native policy/UI acceptance passed; integrated recorder gate and physical soak pending. Keep open. |
| [#8](https://github.com/esdu/app2/issues/8) · [PR #26](https://github.com/esdu/app2/pull/26) | Supported NV12 preference with BGRA fallback, explicit supported 30 fps selection/readback, sample validation and configuration/drop diagnostics. [NV12 note](ISSUE_8_NV12_BASELINE.md). | Focused NV12 head passed 56 unit/integration and five UI cases, including six format, four NV12 and eighteen recorder cases, with packaging/privacy passed. Combined format/NV12 cases passed. Obtain a green final integrated #2 result and retain decoded evidence for both NV12 ranges with audio on/off: color, frame IDs/PTS, portrait metadata, fallback/errors and fresh-generation state. | Front/rear actual formats/cadence/drops, physical portrait/color/A/V checks and matched BGRA/NV12 CPU/memory/energy/thermal/long-session measurements. Synthetic portrait input does not test sensor rotation. | Focused native correctness passed; final integrated gate and device evidence pending. No measured performance gain. Keep open. |
| [#9](https://github.com/esdu/app2/issues/9) · [PR #28](https://github.com/esdu/app2/pull/28) | Internal `.evaluatePassthrough` candidate with compatibility check, narrow fallback and cleanup. Production `ClipComposer()` remains `.highestQuality` MP4. [Export note](ISSUE_9_EXPORT_EVALUATION.md). | Focused export head passed 58 unit/integration and five UI cases, including seven export and five content cases, with packaging/privacy passed; those twelve export cases also passed in the combined run. Obtain a green final integrated #2/media result and retain evidence for decoded endpoints/non-keyframe trims, A/V joins/gaps, orientation and windows; exercise fallback, cancellation/storage/access errors and leases. Retain actual attempt sequence, bytes and timing attachments. | Early/full/repeated-save iPhone comparison, encoder pressure/drops/thermal/energy, physical front/rear playback, Photos/share consumers, reload/deletion. | Focused native export evaluation passed; integrated regression and physical measurements pending. Default unchanged; no adoption or issue closure claimed. |
| [#10](https://github.com/esdu/app2/issues/10) · [PR #30](https://github.com/esdu/app2/pull/30) | Integrated bounded Off/5/10-second post-roll with fixed media-time intervals, immediate/future leases, nonfreezing positive-tail collection, progress and shorter/error interruption outcomes; independent audio-boundary cleanup. [Post-roll note](ISSUE_10_POST_ROLL.md). | Run integrated `RollingRecorderTests`, `AudioBoundaryTests`, preference/model/feedback and dim countdown coverage after #2/#3/#4: exact decoded beginning/cutoff/first post-trigger frame, all windows, retained pre-trigger files, bounded finalization, partial/error reporting, duplicate taps, cancellation/restart, background/library/interruption/stall/low disk and complete cleanup. The exact-endpoint/warmup/window matrix timed out after 120 seconds in both combined and PR #30 runs. Other post-roll cleanup/shorter/file-bound cases passed; obtain a complete green final-head result without losing scenarios. | Physical capture/storage/PCM-packet/lifecycle validation after native correctness; real work/file bounds, thermal and VoiceOver behavior remain pending. | Implementation integrated; native matrix failed by timeout and physical acceptance is pending. Keep open. Off remains the original retrospective behavior. |
| [#11](https://github.com/esdu/app2/issues/11) · [PR #29](https://github.com/esdu/app2/pull/29) | Integrated DEBUG-only alternative continuous segmented-MOV snapshot experiment and comparison suite, using the #10 fixed-interval seam. [Continuous snapshot note](ISSUE_11_CONTINUOUS_SNAPSHOT.md). This is not an fMP4 writer; production Off is unchanged. | The combined run executed seven `ContinuousSnapshotTests`; the all-window/consecutive-save case failed to find an audio track while six passed. Correct the failure and rerun with #2/#9/#10 suites: compare Save-discarded versus encoder-backpressured counts, decode fixed endpoints/A/V for all windows, consecutive/warmup saves, delayed callbacks/deadlines, stopped future-audio-boundary cleanup, low disk/export failure and leases. The assessment is no-go: aggregate capture-plus-export hard reservation/growth bounds remain unresolved; sampled small-fixture bytes do not establish them. | Matched iPhone baseline/prototype continuity, latency, memory, actual peak disk use and energy/thermal measurements; review migration only if correctness, resource bounds and measured benefits justify adoption. | Prototype/assessment integrated; native content case failed; aggregate budget and physical acceptance pending. Keep open; **no-go for production adoption**. |
| [#12](https://github.com/esdu/app2/issues/12) · [PR #22](https://github.com/esdu/app2/pull/22) | [1080p30 no-go assessment](ISSUE_12_QUALITY_FEASIBILITY.md), resource calculator and three [actual-resolution harness tests](ISSUE_12_QUALITY_HARNESS.md): portrait 720×1280/1080×1920, early/rollover/full-15s trimming and stopped-generation isolation. No runtime preset/settings added; 720p retained, 4K/60 deferred. | All three `QualityResolutionRecorderTests` passed in focused run 44109821028 (49 unit/integration + five UI total, packaging/privacy passed) and in combined run 44121676033. Obtain green final integrated #2/#7/#8 gates. The new full-size fixture is **2 fps, 112 source frames and one full 15s window**, not all four full-resolution windows or sustained 30 fps. Its frame ID/PTS, PCM and orientation assertions passed for that bounded fixture. Quality preference/capability/fallback tests and measured/enforced peak working-set/retention analysis remain future gates; calculator arithmetic is not an encoder bound. | Exact device/OS/build/camera capability table, sample/export dimensions/cadence/bitrate and sustained longest-window audio on/off, repeated-save, low-storage/system-pressure/quality measurements. | No-go decision and bounded software coverage present; **full issue acceptance incomplete**. Final integrated regression, broader full-resolution and physical requirements remain open; no validated 1080p bitrate or support claim. |
| [#13](https://github.com/esdu/app2/issues/13) · [PR #23](https://github.com/esdu/app2/pull/23) | [Voice feasibility note](ISSUE_13_VOICE_FEASIBILITY.md) recommends **defer** and supplies capability/permission matrix, lifecycle/stale-callback design, failure/privacy language, hardware-button comparison and scoped test/evaluation plan. No runtime speech, permission or production start-path change. | Assessment is documentation-only and its bounded deliverable is complete. Any later implementation must separately execute the specified fake/UI/privacy tests and reuse #2/#3/#4. | Every device/OS/locale capability, recognition reliability and energy result is unvalidated; a later opt-in prototype needs the specified corpus and matched hardware runs. Hardware was conditional for this assessment. | Eligible for closure **as a deferred assessment only**. This neither completes a voice feature nor authorizes enabling recognition. No GitHub closure is asserted here. |
| [#14](https://github.com/esdu/app2/issues/14) · [PR #20](https://github.com/esdu/app2/pull/20) | Bounded stop-on-first-failure stress selection, independent run evidence, robust summaries/crash extraction and retained artifacts. [CI note](ISSUE_14_CI_DIAGNOSTICS.md). Local Python fixture tests are reported in that note. | Focused run 44107888519 passed 28 unit/integration, five UI, three separate fourteen-case stress passes, eighteen Python fixtures and packaging/privacy. Later failed integration and PR #30 runs retained earlier failures across Xcode host restart, exited 65 and uploaded summaries/artifacts; their integrated stress step was skipped. Obtain successful final-head integrated stress and regression evidence. Verify injected failure/crash, timeout/missing bundle and extraction failure remain non-green with identifiable first failing evidence. Synthetic fixtures alone do not prove real Actions failure behavior. | No new hardware benchmark required; signed distribution remains separate. | Diagnostics implementation present; first failed integration run retained summary/artifacts. Focused ordinary/stress/archive execution passed; final integrated regression/stress and remaining failure-path acceptance pending. Keep open. |
| [#15](https://github.com/esdu/app2/issues/15) | Handoff/rollup tracker, dependency graph and this acceptance ledger. [Graph PR #16](https://github.com/esdu/app2/pull/16); [integration PR #18](https://github.com/esdu/app2/pull/18). | Link each focused change and its final-head verification evidence. Update child status only against its own completed scope; record failed iterations and blockers. | Retain explicit device and signing gates across children. | **Tracker remains open.** Child source integration does not complete all children or the rollup. |

## Evidence needed for the next status update

1. Record the final integrated commit and native CI URL/result bundles. Run the
   ordinary suite, narrow repeated suites, source/built/archive privacy validation
   and unsigned Release archive. Record failures as failures; update this ledger
   from observed results rather than planned assertions.
2. Validate the integrated #10 and isolated #11 prototype separately. Their shared
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
