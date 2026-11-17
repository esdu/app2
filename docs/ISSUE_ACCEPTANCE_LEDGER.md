# Child issue acceptance ledger

This is the acceptance inventory for [app2 #15](https://github.com/esdu/app2/issues/15),
reviewed against the supplied #2–#15 issue snapshot and integration commit
`9da97e1` on 2026-11-17. It records scoped deliverables and remaining evidence; it
does not change GitHub issue states. #15 remains the open rollup tracker.

The dependency graph, implementation gates and shared-file merge order live in
[ISSUE_DEPENDENCIES.md](ISSUE_DEPENDENCIES.md). A source change being present does
not establish that its dependency's acceptance tests passed. In particular, the
#2 recorder correctness gate is still awaiting a successful native result.

## Evidence boundary

CI status snapshot: 2026-11-17 14:50 UTC; queued/running states are not final results.

- The first integration [native run 44104753849](https://github.com/esdu/app2/actions/runs/44104753849)
  at `2575db6` **failed during compilation** on the actor-isolated autoclosure in
  `DimScreenCoordinator` deinitialization (Xcode 16.4, iOS 18.5, iPhone SE 3).
  Tests, stress, built-app privacy and archive steps were skipped. Source privacy/tooling checks and always-run
  diagnostics/artifact upload succeeded. Diagnostics reported missing tests and
  unavailable counts rather than invented results; they do not turn this
  iteration green.
- Commit `0d39349` snapshots dim state before that restoration decision. The next
  integration [run 44106794217](https://github.com/esdu/app2/actions/runs/44106794217)
  at `9da97e1` is **queued** at this snapshot. The fix and newly registered suites
  are not yet validated by a completed native run. The failed iteration remains
  recorded independently.
- Independent preferences [run 44104742324](https://github.com/esdu/app2/actions/runs/44104742324)
  at `1d6bef3` compiled the app/tests and passed built-app privacy validation.
  Tests are **in progress**, with archive still pending; no passing test result
  or combined-integration result is claimed.
- Child notes report Linux source/privacy/diff checks and, for #14, Python fixture
  tests. These establish only their stated checks, not AVFoundation execution.
- [VALIDATION.md](VALIDATION.md) and [PRIVACY_VALIDATION.md](PRIVACY_VALIDATION.md)
  cite successful CI for the earlier `87bf16a` baseline. That evidence does not
  validate this integration or its added User Defaults declaration. Source,
  built-app and unsigned-archive privacy checks must run again for the final head.
- No physical iPhone run, hardware-button delivery, brightness restoration,
  haptic/VoiceOver device check, thermal/energy measurement or signed distribution
  validation is claimed. [PHYSICAL_TESTING.md](PHYSICAL_TESTING.md) remains pending.
- #10 post-roll, #11 DEBUG continuous MOV experiment, independent audio-boundary
  tests, dim countdown and #12 actual-resolution tests are now integrated source.
  The #10/#11 rows distinguish implementation from unexecuted acceptance and
  prototype adoption; production Off still uses the freezing retrospective path.

## Scoped status and remaining acceptance

“Pending native” means implementation and assertions are present for review, but
the required Apple-platform result is absent. It does not mean ready for closure.
Assessment completion is separate from permission to enable a runtime feature.
Focused PR links identify review scope, not a passed CI run or merged change.

| Issue | Integrated implementation or assessment | Native/software acceptance still needed | Physical or other acceptance still needed | Honest closure status |
| --- | --- | --- | --- | --- |
| [#2](https://github.com/esdu/app2/issues/2) · [PR #19](https://github.com/esdu/app2/pull/19) | Production `RollingRecorder` ingestion seam, deterministic timestamped A/V source, rotation/leases/library tests and diagnostics; independent 10 ms PCM boundary/leading/lagging-delivery coverage. [Harness note](ISSUE_2_RECORDER_HARNESS.md). | Execute `RollingRecorderTests`, `CameraModelTests` and media tests: all four 300-second logical retention windows with audio on/off, decoded endpoints/counts/audio markers, rollover/warmup/repeated saves, lifecycle/failure/watchdog and cleanup. Retain failed media/timing evidence. Run the added `AudioBoundaryTests` for session-start PCM trimming and independent leading/lagging packet delivery across rollovers; these assertions are not yet observed results. | Real camera cadence/orientation, microphone negotiation, interruption/protected-data behavior and sustained pressure/storage runs. Low-resolution accelerated fixtures establish no device performance. | Implementation present; acceptance pending native and separate device checks. Keep open. |
| [#3](https://github.com/esdu/app2/issues/3) · [PR #17](https://github.com/esdu/app2/pull/17) | Typed, versioned, tolerant preference store; guarded model updates; disposable test domains; CA92.1 declaration. [Preferences note](ISSUE_3_PREFERENCES.md). | Independent branch compilation/built privacy passed; tests are still running (see run above). Obtain completed `PreferenceTests`, `PreferenceUITests` and existing permission/startup cancellation results for the final integrated head. Verify stopped relaunch and no permission/capture request; validate source/built/archive manifests with the new declaration. | No feature-specific hardware benchmark required; retain the shared release/privacy gates. | Implementation present; pending native evidence. Keep open until scoped acceptance passes. |
| [#4](https://github.com/esdu/app2/issues/4) · [PR #21](https://github.com/esdu/app2/pull/21) | One guarded save path, commit-based nonmodal status, injectable haptics/announcements and replacement-safe timeout. [Feedback note](ISSUE_4_SAVE_FEEDBACK.md). | Run `SaveFeedbackTests`, model tests and repeated save/playback/delete/navigation UI flow. Verify failures, lease release, inactive completion and stale timeout behavior. | Physical haptic delivery and VoiceOver announcements/focus, accessible text and navigation behavior. | Implementation present; native/accessibility evidence pending. Keep open. |
| [#5](https://github.com/esdu/app2/issues/5) · [PR #25](https://github.com/esdu/app2/pull/25) | Public `AVCaptureEventInteraction` adapter, iOS 17.2 availability gate, iOS 17.0–17.1 onscreen fallback, guarded release routing and stale callback rejection. [Button note](ISSUE_5_VOLUME_BUTTONS.md). | Build at deployment target 17.0; run `CapturePressRouterTests`, `HardwareSaveRoutingTests` and onscreen UI regressions. Synthetic callback tests do not exercise hardware delivery. | Both buttons, one clip per press/hold, rapid/save-finalization presses, dim operation, navigation/interruption cleanup, normal volume outside eligible capture and minimum-OS fallback. | Implementation present; physical validation explicitly required before production support is claimed. Keep open. |
| [#6](https://github.com/esdu/app2/issues/6) · [PR #24](https://github.com/esdu/app2/pull/24) | Explicit dim view with touch Save/Wake, scene-specific brightness ownership/restoration, battery status and accessible post-roll countdown. Compilation failure in the first integration run has a source fix, still awaiting native verification. [Dim/battery note](ISSUE_6_DIM_BATTERY.md). | Run `DimBatteryTests` and `DimRecordingUITests`: all exits, external brightness changes, observer cleanup, background/no auto-resume, large text and touch-only save. | Actual brightness restoration across wake/stop/library/call/Home/lock and termination/relaunch; Control Center changes; charging updates; VoiceOver/XXXL/small-screen operation at dim brightness. No energy-saving claim without measurement. | Implementation present; native and hardware acceptance pending. Keep open. |
| [#7](https://github.com/esdu/app2/issues/7) · [PR #27](https://github.com/esdu/app2/pull/27) | Serious warning, critical pause/start block, explicit restart after cooling, no silent quality change. [Thermal note](ISSUE_7_THERMAL.md). | Run `ThermalTests`, `ThermalUITests`, recorder, cancellation and feedback suites. Verify stale notifications/start races, saved-file/lease preservation and exactly-once stops; satisfy #2 correctness gate. | Sustained physical soak with timestamped thermal states, audio/window variants, pending saves, decoded outputs and recovery. Simulator injection validates policy only. | Implementation present; native and physical soak pending. Keep open. |
| [#8](https://github.com/esdu/app2/issues/8) · [PR #26](https://github.com/esdu/app2/pull/26) | Supported NV12 preference with BGRA fallback, explicit supported 30 fps selection/readback, sample validation and configuration/drop diagnostics. [NV12 note](ISSUE_8_NV12_BASELINE.md). | Run `CaptureFormatPolicyTests`, `NV12RecorderTests` and #2 suites. Decode both NV12 ranges with audio on/off; verify color, frame IDs/PTS, portrait metadata, fallback/errors and fresh-generation state. | Front/rear actual formats/cadence/drops, physical portrait/color/A/V checks and matched BGRA/NV12 CPU/memory/energy/thermal/long-session measurements. Synthetic portrait input does not test sensor rotation. | Implementation present; native and device evidence pending. No measured performance gain. Keep open. |
| [#9](https://github.com/esdu/app2/issues/9) · [PR #28](https://github.com/esdu/app2/pull/28) | Internal `.evaluatePassthrough` candidate with compatibility check, narrow fallback and cleanup. Production `ClipComposer()` remains `.highestQuality` MP4. [Export note](ISSUE_9_EXPORT_EVALUATION.md). | Run `ClipExportTests` and `ClipExportContentTests` with #2/media suites: decode endpoints/non-keyframe trims, A/V joins/gaps, orientation and windows; exercise fallback, cancellation/storage/access errors and leases. Retain actual attempt sequence, bytes and timing attachments. | Early/full/repeated-save iPhone comparison, encoder pressure/drops/thermal/energy, physical front/rear playback, Photos/share consumers, reload/deletion. | Evaluation code present; measurements/correctness acceptance pending. Default unchanged; no adoption or issue closure claimed. |
| [#10](https://github.com/esdu/app2/issues/10) · [PR #30](https://github.com/esdu/app2/pull/30) | Integrated bounded Off/5/10-second post-roll with fixed media-time intervals, immediate/future leases, nonfreezing positive-tail collection, progress and shorter/error interruption outcomes; independent audio-boundary cleanup. [Post-roll note](ISSUE_10_POST_ROLL.md). | Run integrated `RollingRecorderTests`, `AudioBoundaryTests`, preference/model/feedback and dim countdown coverage after #2/#3/#4: exact decoded beginning/cutoff/first post-trigger frame, all windows, retained pre-trigger files, bounded finalization, partial/error reporting, duplicate taps, cancellation/restart, background/library/interruption/stall/low disk and complete cleanup. Assertions are present, not yet executed evidence. | Physical capture/storage/PCM-packet/lifecycle validation after native correctness; real work/file bounds, thermal and VoiceOver behavior remain pending. | Implementation integrated; native and physical acceptance pending. Keep open. Off remains the original retrospective behavior. |
| [#11](https://github.com/esdu/app2/issues/11) · [PR #29](https://github.com/esdu/app2/pull/29) | Integrated DEBUG-only alternative continuous segmented-MOV snapshot experiment and comparison suite, using the #10 fixed-interval seam. [Continuous snapshot note](ISSUE_11_CONTINUOUS_SNAPSHOT.md). This is not an fMP4 writer; production Off is unchanged. | Run `ContinuousSnapshotTests` with #2/#9/#10 suites: compare Save-discarded versus encoder-backpressured counts, decode fixed endpoints/A/V for all windows, consecutive/warmup saves, delayed callbacks/deadlines, stopped future-audio-boundary cleanup, low disk/export failure and leases. The assessment is no-go: aggregate capture-plus-export hard reservation/growth bounds remain unresolved; sampled small-fixture bytes do not establish them. | Matched iPhone baseline/prototype continuity, latency, memory, actual peak disk use and energy/thermal measurements; review migration only if correctness, resource bounds and measured benefits justify adoption. | Prototype/assessment integrated; native comparison, aggregate budget and physical acceptance pending. Keep open; **no-go for production adoption**. |
| [#12](https://github.com/esdu/app2/issues/12) · [PR #22](https://github.com/esdu/app2/pull/22) | [1080p30 no-go assessment](ISSUE_12_QUALITY_FEASIBILITY.md), resource calculator and three [actual-resolution harness tests](ISSUE_12_QUALITY_HARNESS.md): portrait 720×1280/1080×1920, early/rollover/full-15s trimming and stopped-generation isolation. No runtime preset/settings added; 720p retained, 4K/60 deferred. | Execute `QualityResolutionRecorderTests` plus #2/#7/#8 gates. The new full-size fixture is **2 fps, 112 source frames and one full 15s window**, not all four full-resolution windows or sustained 30 fps. Actual frame IDs/PTS, PCM and orientation assertions await native results. Quality preference/capability/fallback tests and measured/enforced peak working-set/retention analysis remain future gates; calculator arithmetic is not an encoder bound. | Exact device/OS/build/camera capability table, sample/export dimensions/cadence/bitrate and sustained longest-window audio on/off, repeated-save, low-storage/system-pressure/quality measurements. | No-go decision and bounded software coverage present; **full issue acceptance incomplete**. Native, broader full-resolution and physical requirements remain open; no validated 1080p bitrate or support claim. |
| [#13](https://github.com/esdu/app2/issues/13) · [PR #23](https://github.com/esdu/app2/pull/23) | [Voice feasibility note](ISSUE_13_VOICE_FEASIBILITY.md) recommends **defer** and supplies capability/permission matrix, lifecycle/stale-callback design, failure/privacy language, hardware-button comparison and scoped test/evaluation plan. No runtime speech, permission or production start-path change. | Assessment is documentation-only and its bounded deliverable is complete. Any later implementation must separately execute the specified fake/UI/privacy tests and reuse #2/#3/#4. | Every device/OS/locale capability, recognition reliability and energy result is unvalidated; a later opt-in prototype needs the specified corpus and matched hardware runs. Hardware was conditional for this assessment. | Eligible for closure **as a deferred assessment only**. This neither completes a voice feature nor authorizes enabling recognition. No GitHub closure is asserted here. |
| [#14](https://github.com/esdu/app2/issues/14) · [PR #20](https://github.com/esdu/app2/pull/20) | Bounded stop-on-first-failure stress selection, independent run evidence, robust summaries/crash extraction and retained artifacts. [CI note](ISSUE_14_CI_DIAGNOSTICS.md). Local Python fixture tests are reported in that note. | The failed integration run exercised summary/artifact steps; native ordinary/stress selectors, real test-result schemas/exports, job budget and built/archive checks still need completed results. Verify injected failure/crash, timeout/missing bundle and extraction failure remain non-green with identifiable first failing evidence. Synthetic fixtures alone do not prove real Actions failure behavior. | No new hardware benchmark required; signed distribution remains separate. | Diagnostics implementation present; first failed integration run retained summary/artifacts. Successful ordinary/stress/archive execution and remaining failure-path acceptance pending. Keep open. |
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
