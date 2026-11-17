# Physical iPhone acceptance checklist

Status: **NOT EXECUTED — every check below is pending on a physical iPhone.**
Simulator results and injected policy tests do not complete hardware acceptance.
Record device model, iOS version, build commit, test date, camera, audio setting,
retention/post-roll settings, available disk, battery/charging state and ambient
conditions for each run. Attach observed results, media, logs and Instruments traces;
a checklist entry without evidence remains not executed. Use non-sensitive footage
and an adult test subject for initial engineering verification.

1. **Not executed — explicit start and permissions.** Fresh install must show no
   camera/microphone indicator, permission prompt or capture before Start Buffer.
   Deny camera, verify explanation/Settings recovery and explicit restart. With
   audio disabled, verify no microphone request; enable audio and test microphone
   denial/recovery. Background during permission grant/startup and start/stop
   rapidly; no stale completion may activate capture or report false success.

2. **Not executed — persisted preferences (#3).** While stopped, choose each
   supported retention window, audio on/off and front/rear camera; terminate and
   relaunch. Verify selections survive, launch is stopped and capture still needs
   Start Buffer. Repeat after a permission denial and unavailable camera choice.
   Verify settings cannot change during startup/capture. Repeat for post-roll
   Off/5s/10s after that feature is integrated, without restoring recording state.

3. **Not executed — save feedback (#4).** Trigger successful, duplicate/busy and
   failed saves. Verify routine success is readable without dismissing a modal,
   haptics occur once at the intended event, and success appears only after local
   publication. Errors remain actionable. Check VoiceOver announcements and focus,
   largest accessibility text, Reduce Motion, small display and one-handed use;
   saving/status feedback must remain understandable without vibration or sound.

4. **Not executed — hardware volume input (#5).** On supported iOS, test both
   volume buttons: short press, repeated presses, long press and presses during a
   pending save must produce the intended single save per eligible press, without
   duplicate clips. Repeat while dimmed and after stop, library navigation,
   interruption/background and return. Outside active capture the buttons must
   retain normal system-volume behavior. On an older supported iOS/device without
   capture-event support, verify an accessible touch save path and clear fallback;
   no hardware-button support may be required to save or wake.

5. **Not executed — dim mode and brightness ownership (#6).** Start from several
   user brightness levels; dim repeatedly, save by touch, wake, stop, enter library,
   background/lock and handle a call. Verify a discoverable accessible wake/save
   path, accurate capture state, and restoration on every exit, including failed
   start and thermal stop. Change brightness deliberately in Control Center while
   dimmed; verify the newer external value is preserved under the documented
   ownership rule. Do not leave another app at the dim value. Check VoiceOver,
   touch target/focus, idle behavior, battery updates, charging transitions and
   unavailable battery readings. No energy saving is established by visual dimming.

6. **Not executed — retention, media and actual delivery (#2/#8).** For each
   15/30/60/120-second window, film a visible running clock with audible claps for
   at least twice the interval; save at warmup and mid-segment triggers, then save
   repeatedly. Check actual beginning/end, duration, every decoded video frame and
   decoded audio sample spans across two-second joins, plus lip/clap sync. Record
   native and delivered dimensions, pixel format/range, requested and observed
   cadence, encoder/delegate drops and orientation for front/rear, audio on/off.
   Compare matched BGRA/NV12 720p30 runs per the
   [format protocol](ISSUE_8_NV12_BASELINE.md); any supported fallback must be
   identified in logs/results. A requested 30 fps setting is not delivered-cadence
   evidence. Check preview/export portrait orientation, front mirroring and color.

7. **Not executed — real microphone boundaries.** Record callback packet sizes,
   sample rate/channels and A/V PTS ordering. Exercise audio leading and lagging
   video, packets straddling writer starts/cutoffs, repeated saves and interruptions.
   Compare matched source intervals and decoded PCM sample coverage/tone or clap
   markers; AAC output packet counts need not equal input packet counts. Verify no
   dropped/duplicated boundary content, unexplained silence, overlap or drift.
   Repeat with actual microphone packet cadence rather than only one synthetic
   audio buffer per video frame, and record any missing-audio timeout behavior.

8. **Not executed — thermal policy (#7).** During a 120-second-window soak, record
   observed nominal/fair/serious/critical transitions and ambient conditions.
   Serious pressure must produce a readable warning without claiming a quality
   reduction that did not occur. At critical pressure, capture must stop with an
   explanation; test already-critical startup, transition during startup/save,
   duplicate notifications, oscillation and cooling while stopped. Verify retained
   save sources and previously published clips survive or a clear save error is
   shown. Cooling/foreground return must never restart capture automatically;
   recovery requires an explicit Start Buffer. Any transition not physically
   observed stays pending even if the injected model test passes.

9. **Not executed — post-roll semantics (#10).** For Off/5s/10s and every retention
   window, mark trigger time on the filmed clock and compare the fixed requested
   interval [trigger − buffer, trigger + post-roll] with decoded output, including
   the first post-trigger frame and matching audio. Repeat during warmup and across
   mid-segment triggers/eviction; pre-trigger history must survive collection and
   export. Exercise duplicate taps, volume/touch saves, Stop, library entry, lock,
   Home/app switch, incoming call, Siri, video stall, low disk and thermal stop
   during collection/finalization. Capture must stop when lifecycle requires it.
   Expect one bounded result: safely finalized shorter media with explicit partial
   wording, or a visible cancellation/error. Never label a shortened clip complete,
   wait indefinitely, extend the original target or restart to finish post-roll.
   Check remaining-time/status accessibility and lease cleanup after every outcome.

10. **Not executed — storage, work and failure limits.** Run at least 30 minutes
    at 120 seconds with audio and repeated saves/post-roll. Measure peak memory,
    CPU, file count, in-flight encoding and actual maximum temporary bytes.
    Account separately for active/boundary-held/finalizing/completed capture files,
    leased/retired generations, export/library staging and completed output awaiting
    publication; do not double count a lease or omit hard-linked retained bytes.
    Verify completed-segment quota failure, the sampled capture-file guard and
    its measured overshoot, low-space stop, bounded audio lookahead and writer
    overload behavior. The capture-directory limit alone does not prove a combined
    capture-plus-export bound. Delay completion and fail source/output writes;
    verify bounded settlement and cleanup of files, leases and staging after
    success, failure, cancellation, stop and explicit restart. Saved clips survive.

11. **Not executed — export and continuous-snapshot comparisons (#9/#11).** Follow
    the [export comparison protocol](ISSUE_9_EXPORT_EVALUATION.md#results-and-limits)
    and [continuous snapshot protocol](ISSUE_11_CONTINUOUS_SNAPSHOT.md#physical-comparison-and-migration-gate)
    on equivalent hardware/settings/scenes. Include early/full-window/repeated
    saves, decoded non-keyframe endpoints, A/V joins, actual strategy/fallback,
    Save-attributable loss separately from encoder backpressure, wall latency,
    bytes, memory, CPU, energy and thermal traces. Include staging in peak storage.
    Check playback, Photos grant/denial and share consumers for each export path.
    Record no invented measurements: passthrough and the DEBUG continuous-MOV
    prototype remain opt-in assessments; simulator throughput does not authorize
    a production default change or prove energy benefits/fewer encoders.

12. **Not executed — lifecycle and persistent library.** While buffering and
    saving, test lock/unlock, app switching, notification center, Control Center,
    phone/FaceTime and permission dialogs. Confirm indicators/capture stop where
    required and no automatic resume. Save, terminate, relaunch, preview, export to
    Photos, share, cancel and confirm deletion; only the selected clip is deleted.
    Clips must survive buffer eviction and relaunch. Test near-full storage,
    interrupted export and protected-data unavailability during lock; verify failed
    staging is cleaned without discarding an existing published clip.

13. **Not executed — privacy and accessibility completion.** Inspect actual app
    network activity for absent media uploads/analytics and inspect complete file
    protection/backup exclusion on capture, staging and published files. Verify
    VoiceOver focus/order, visible save/wake/start controls and playback dismissal
    throughout dim, collecting, saving, paused, error and thermal states. Record
    that uninstall deletes local clips. Finish built-app/archive privacy checks
    separately; these do not replace device file-protection checks.

Release acceptance requires recorded results and resolution of hardware-specific
failures. All entries above remain **not executed** until that evidence is attached.
This is not a substitute for direct parental supervision or a dedicated baby monitor.
