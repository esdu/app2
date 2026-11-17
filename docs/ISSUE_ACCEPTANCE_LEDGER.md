# Child issue acceptance ledger

This is the acceptance inventory for [app2 #15](https://github.com/esdu/app2/issues/15),
reviewed against the supplied #2–#15 issue snapshot and integration commit
`2575db6` on 2026-11-17. It records scoped deliverables and remaining evidence; it
does not change GitHub issue states. #15 remains the open rollup tracker.

The dependency graph, implementation gates and shared-file merge order live in
[ISSUE_DEPENDENCIES.md](ISSUE_DEPENDENCIES.md). A source change being present does
not establish that its dependency's acceptance tests passed. In particular, the
#2 recorder correctness gate is still awaiting native execution.

## Evidence boundary

- The integration includes source, test definitions and decision notes. Its new
  Swift/XCTest/XCUITest suites, simulator packaging and unsigned Release archive
  **have not yet been validated by a native macOS CI run** at this review point.
  Project registration alone is not a build or test result.
- Child notes report Linux source/privacy/diff checks and, for #14, Python fixture
  tests. These establish only their stated checks, not AVFoundation execution.
- [VALIDATION.md](VALIDATION.md) and [PRIVACY_VALIDATION.md](PRIVACY_VALIDATION.md)
  cite successful CI for the earlier `87bf16a` baseline. That evidence does not
  validate this integration or its added User Defaults declaration. Source,
  built-app and unsigned-archive privacy checks must run again for the final head.
- No physical iPhone run, hardware-button delivery, brightness restoration,
  haptic/VoiceOver device check, thermal/energy measurement or signed distribution
  validation is claimed. [PHYSICAL_TESTING.md](PHYSICAL_TESTING.md) remains pending.
- Draft work in another worktree is not an integrated deliverable. The #10/#11
  rows deliberately distinguish planned/prototype work from accepted behavior.

## Scoped status and remaining acceptance

“Pending native” means implementation and assertions are present for review, but
the required Apple-platform result is absent. It does not mean ready for closure.
Assessment completion is separate from permission to enable a runtime feature.

| Issue | Integrated implementation or assessment | Native/software acceptance still needed | Physical or other acceptance still needed | Honest closure status |
| --- | --- | --- | --- | --- |
| [#2](https://github.com/esdu/app2/issues/2) | Production `RollingRecorder` ingestion seam, deterministic timestamped A/V source, rotation/leases/library tests and diagnostics. [Harness note](ISSUE_2_RECORDER_HARNESS.md). | Execute `RollingRecorderTests`, `CameraModelTests` and media tests: all four 300-second logical retention windows with audio on/off, decoded endpoints/counts/audio markers, rollover/warmup/repeated saves, lifecycle/failure/watchdog and cleanup. Retain failed media/timing evidence. The committed explicit offset case is positive; broader offsets remain an extension to verify. | Real camera cadence/orientation, microphone negotiation, interruption/protected-data behavior and sustained pressure/storage runs. Low-resolution accelerated fixtures establish no device performance. | Implementation present; acceptance pending native and separate device checks. Keep open. |
| [#3](https://github.com/esdu/app2/issues/3) | Typed, versioned, tolerant preference store; guarded model updates; disposable test domains; CA92.1 declaration. [Preferences note](ISSUE_3_PREFERENCES.md). | Run `PreferenceTests`, `PreferenceUITests` and existing permission/startup cancellation coverage. Verify stopped relaunch and no permission/capture request; validate source/built/archive manifests with the new declaration. | No feature-specific hardware benchmark required; retain the shared release/privacy gates. | Implementation present; pending native evidence. Keep open until scoped acceptance passes. |
| [#4](https://github.com/esdu/app2/issues/4) | One guarded save path, commit-based nonmodal status, injectable haptics/announcements and replacement-safe timeout. [Feedback note](ISSUE_4_SAVE_FEEDBACK.md). | Run `SaveFeedbackTests`, model tests and repeated save/playback/delete/navigation UI flow. Verify failures, lease release, inactive completion and stale timeout behavior. | Physical haptic delivery and VoiceOver announcements/focus, accessible text and navigation behavior. | Implementation present; native/accessibility evidence pending. Keep open. |
| [#5](https://github.com/esdu/app2/issues/5) | Public `AVCaptureEventInteraction` adapter, iOS 17.2 availability gate, iOS 17.0–17.1 onscreen fallback, guarded release routing and stale callback rejection. [Button note](ISSUE_5_VOLUME_BUTTONS.md). | Build at deployment target 17.0; run `CapturePressRouterTests`, `HardwareSaveRoutingTests` and onscreen UI regressions. Synthetic callback tests do not exercise hardware delivery. | Both buttons, one clip per press/hold, rapid/save-finalization presses, dim operation, navigation/interruption cleanup, normal volume outside eligible capture and minimum-OS fallback. | Implementation present; physical validation explicitly required before production support is claimed. Keep open. |
| [#6](https://github.com/esdu/app2/issues/6) | Explicit dim view with touch Save/Wake, scene-specific brightness ownership/restoration and notification-based battery status. [Dim/battery note](ISSUE_6_DIM_BATTERY.md). | Run `DimBatteryTests` and `DimRecordingUITests`: all exits, external brightness changes, observer cleanup, background/no auto-resume, large text and touch-only save. | Actual brightness restoration across wake/stop/library/call/Home/lock and termination/relaunch; Control Center changes; charging updates; VoiceOver/XXXL/small-screen operation at dim brightness. No energy-saving claim without measurement. | Implementation present; native and hardware acceptance pending. Keep open. |
| [#7](https://github.com/esdu/app2/issues/7) | Serious warning, critical pause/start block, explicit restart after cooling, no silent quality change. [Thermal note](ISSUE_7_THERMAL.md). | Run `ThermalTests`, `ThermalUITests`, recorder, cancellation and feedback suites. Verify stale notifications/start races, saved-file/lease preservation and exactly-once stops; satisfy #2 correctness gate. | Sustained physical soak with timestamped thermal states, audio/window variants, pending saves, decoded outputs and recovery. Simulator injection validates policy only. | Implementation present; native and physical soak pending. Keep open. |
| [#8](https://github.com/esdu/app2/issues/8) | Supported NV12 preference with BGRA fallback, explicit supported 30 fps selection/readback, sample validation and configuration/drop diagnostics. [NV12 note](ISSUE_8_NV12_BASELINE.md). | Run `CaptureFormatPolicyTests`, `NV12RecorderTests` and #2 suites. Decode both NV12 ranges with audio on/off; verify color, frame IDs/PTS, portrait metadata, fallback/errors and fresh-generation state. | Front/rear actual formats/cadence/drops, physical portrait/color/A/V checks and matched BGRA/NV12 CPU/memory/energy/thermal/long-session measurements. Synthetic portrait input does not test sensor rotation. | Implementation present; native and device evidence pending. No measured performance gain. Keep open. |
| [#9](https://github.com/esdu/app2/issues/9) | Internal `.evaluatePassthrough` candidate with compatibility check, narrow fallback and cleanup. Production `ClipComposer()` remains `.highestQuality` MP4. [Export note](ISSUE_9_EXPORT_EVALUATION.md). | Run `ClipExportTests` and `ClipExportContentTests` with #2/media suites: decode endpoints/non-keyframe trims, A/V joins/gaps, orientation and windows; exercise fallback, cancellation/storage/access errors and leases. Retain actual attempt sequence, bytes and timing attachments. | Early/full/repeated-save iPhone comparison, encoder pressure/drops/thermal/energy, physical front/rear playback, Photos/share consumers, reload/deletion. | Evaluation code present; measurements/correctness acceptance pending. Default unchanged; no adoption or issue closure claimed. |
| [#10](https://github.com/esdu/app2/issues/10) | No complete post-roll deliverable in the reviewed integration. Work toward Off/5/10-second fixed media-time intervals and a nonfreezing collection path is incomplete. | Integrate/review implementation and tests after #2/#3/#4. Prove immediate pre-trigger/future pinning, exact decoded boundaries including first post-trigger frame, full-window lease survival, bounded collection/cleanup, partial/error outcomes and accurate progress. Cover all windows, duplicate taps, stop/restart/background/library/interruption/stall/low disk. | Physical capture/storage/lifecycle validation after native correctness. | Incomplete; keep open. Neither a preference/UI draft nor later snapshot alone satisfies acceptance. |
| [#11](https://github.com/esdu/app2/issues/11) | Alternative continuous MOV snapshot design is an investigation/prototype, not an adopted fMP4 replacement. No completed prototype or comparative result is integrated at the reviewed head. | Finish isolated opt-in prototype and comparison with #2/#9 and the #10 interval contract. Prove no Save-induced intake gap; decode all endpoints/A/V; cover all windows, warmup, repeated saves, pending interruption, delayed completion/disk failure, bounded memory/work/bytes and complete cleanup. Record go/no-go and migration decision. | Matched iPhone baseline/prototype continuity, latency, memory, maximum disk use and energy/thermal measurements. | Prototype/evaluation pending; keep open and retain production recorder. An alternative MOV design must meet the same acceptance as fMP4. |
| [#12](https://github.com/esdu/app2/issues/12) | [1080p30 no-go assessment](ISSUE_12_QUALITY_FEASIBILITY.md), capability/evidence ledger and reproducible storage screening. No runtime preset/settings added; 720p retained, 4K/60 deferred. | #2/#7/#8 native gates; expanded production harness at both resolutions, stopped-only preset/capability/fallback/generation tests and actual peak working-set/retention analysis remain pending. Calculator arithmetic is not an encoder bound. | Exact device/OS/build/camera capability table, sample/export dimensions/cadence/bitrate and sustained longest-window audio on/off, repeated-save, low-storage/system-pressure/quality measurements. | No-go decision documented, **full issue acceptance incomplete**. Physical and expanded-harness requirements remain open; no validated 1080p bitrate or support claim. |
| [#13](https://github.com/esdu/app2/issues/13) | [Voice feasibility note](ISSUE_13_VOICE_FEASIBILITY.md) recommends **defer** and supplies capability/permission matrix, lifecycle/stale-callback design, failure/privacy language, hardware-button comparison and scoped test/evaluation plan. No runtime speech, permission or production start-path change. | Assessment is documentation-only and its bounded deliverable is complete. Any later implementation must separately execute the specified fake/UI/privacy tests and reuse #2/#3/#4. | Every device/OS/locale capability, recognition reliability and energy result is unvalidated; a later opt-in prototype needs the specified corpus and matched hardware runs. Hardware was conditional for this assessment. | Eligible for closure **as a deferred assessment only**. This neither completes a voice feature nor authorizes enabling recognition. No GitHub closure is asserted here. |
| [#14](https://github.com/esdu/app2/issues/14) | Bounded stop-on-first-failure stress selection, independent run evidence, robust summaries/crash extraction and retained artifacts. [CI note](ISSUE_14_CI_DIAGNOSTICS.md). Local Python fixture tests are reported in that note. | Run real macOS Actions for ordinary/stress selectors, Xcode result schemas/exports, job budget, simulator logs and source/built/archive privacy checks. Verify injected failure/crash, timeout/missing bundle and extraction failure remain non-green with identifiable first failing evidence. Synthetic fixtures alone do not prove real Actions failure behavior. | No new hardware benchmark required; signed distribution remains separate. | Diagnostics implementation present; real CI acceptance pending. Keep open. |
| [#15](https://github.com/esdu/app2/issues/15) | Handoff/rollup tracker, dependency graph and this acceptance ledger. | Link each focused change and its final-head verification evidence. Update child status only against its own completed scope; record failed iterations and blockers. | Retain explicit device and signing gates across children. | **Tracker remains open.** Child source integration does not complete all children or the rollup. |

## Evidence needed for the next status update

1. Record the final integrated commit and native CI URL/result bundles. Run the
   ordinary suite, narrow repeated suites, source/built/archive privacy validation
   and unsigned Release archive. Record failures as failures; update this ledger
   from observed results rather than planned assertions.
2. Complete and review #10 and the isolated #11 prototype separately. Their shared
   fixed-interval/pinning contract must preserve bounded storage/work, protected
   atomic publication, lease lifetime and explicit restart. A prototype does not
   automatically replace the production recorder.
3. Attach physical evidence to the relevant child checklists, with device/iOS/build,
   conditions, duration, observed outputs and pass/fail. Keep unexecuted rows pending.
   Do not infer hardware results from simulator success or capability enumeration.
4. Preserve the decisions: highest-quality export remains the production default;
   1080p30 is no-go pending evidence; 4K/60 remain deferred; voice remains deferred
   with no runtime speech. Signed archive/App Store validation is a later release
   gate and has not been performed.
