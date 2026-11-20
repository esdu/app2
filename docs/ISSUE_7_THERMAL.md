# Thermal pressure (#7)

The production app injects a `ProcessThermalMonitor`. It samples the initial `ProcessInfo.thermalState` before the first UI and receives thermal notifications on MainActor. Notifications carry no cached state into the model: their delivery samples the current state, so an old queued notification cannot reapply an obsolete pressure level. The observer is removed with the monitor. Tests explicitly inject a mutable monitor; DEBUG `--uitesting` launches may set an initial serious/critical state without changing the device's real thermal state.

`ThermalPolicy` leaves nominal/fair capture alone, displays a serious-pressure warning, and blocks capture at critical pressure. Capture remains 720p; this ticket makes no resolution, frame-rate or effective-quality change. Unknown future system thermal states fail closed as critical. A critical launch remains stopped without a capture/permission request. A critical change during startup or buffering invalidates the current operation and pauses through the existing stopper. Duplicate notifications and cooling while paused cannot restart capture. Start becomes available after cooling and after in-flight startup/stop transitions drain; the user must tap it. Start and its completion independently resample the monitor to close missed-notification races.

The model coalesces overlapping stop requests. A thermal-invalidated pending start does not issue a second stop when its completion arrives: production `CameraService.stop` must invalidate any pending startup, as the engine's start generation does. This relies on the production recorder correctness harness (#2) and must land after that gate. Existing storage, encoder, interruption and frame-stall guards stay in place.

Thermal pause leaves the save task and outcome handling active. Already leased segments stay pinned until the task releases them, and a successful export stays in the protected persistent library. A snapshot still being finalized may fail explicitly when the buffer stops; the regular save failure is reported. The warning remains independently visible, and no thermal handler deletes saved clips. App backgrounding still follows its existing feedback and file-protection behavior. Dim mode should restore brightness from the published paused phase; it does not need to infer heat itself.

Verification selectors are `LittleMomentsTests/ThermalTests` and `LittleMomentsUITests/ThermalUITests`, alongside existing cancellation/permission, feedback and production recorder tests. Model tests cover all states, launch hot, delayed startup, missed/stale and duplicate notifications, serious/critical oscillation, backgrounding and no automatic restart. A real system-codec fixture/composer/library test checks pinned source retention across thermal stop and readable saved output; another checks snapshot-finalization failure preserves older files. Simulator injection tests verify policy and UI only. Linux source checks do not establish iOS runtime or physical thermal behavior.

## Physical soak checklist — pending

No physical soak was performed in this workspace. Record a run for each supported device/OS and repeat with audio enabled/disabled and selected buffer durations:

| Evidence | Record during physical run |
| --- | --- |
| Device / OS / app build | Exact model, iOS version and commit |
| Conditions | Ambient temperature, case, power/charging and initial battery |
| Run | Selected duration/audio/camera; wall-clock start/end; foreground use |
| Pressure | Timestamped nominal/fair/serious/critical changes and visible warning |
| Capture | Serious remains 720p; critical pauses; repeated Start blocked while critical |
| Pending work | Save during transition: explicit result; retained leased sources; no saved-file loss |
| Recovery | Cool while paused; verify no capture until explicit Start |
| Outputs | Decode clips; check duration, video/audio tracks, A/V alignment and persistence |
| Lifecycle | Background/foreground and camera-screen exit; brightness restoration if dimmed |
| Result | Pass/fail, thermal duration, logs and any observed limitation |

Do not claim indefinite capture under critical heat or hardware quality/thermal performance from the simulator results.
