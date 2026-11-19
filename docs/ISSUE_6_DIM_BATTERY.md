# Issue #6: explicit dim recording view and battery status

The camera screen now offers **Dim screen** only while buffering. Activation replaces
the preview with a black, scrollable screen showing the capture state, ready duration,
battery/charging status, a touch **Save moment** button, and **Wake screen**. Saving
uses `CameraModel.save()` and the shared `canSave` guard. Success appears in the dim
view without ending dim mode. Errors retain the camera's actionable alert. Dim mode
is never persisted or entered automatically.

## Brightness ownership and lifecycle

`DimScreenCoordinator` accepts `ScreenBrightnessControlling` and `BatteryMonitoring`
adapters. The production screen adapter uses the camera view's `UIWindowScene.screen`,
resolved by `CameraSceneReader`; it does not select an arbitrary connected scene or
use `UIScreen.main`. Moving/detaching the view restores its old screen before rebinding.

An explicit activation snapshots brightness once and applies `min(previous, 0.08)`.
Repeated activation does not take another snapshot or increase brightness on a screen
that was already darker. Wake, stopped/starting/paused/denied/failed capture phases,
library navigation, view disappearance, scene inactivity/background, and coordinator
deinitialization all release observation and restore the snapshot **only while the
coordinator still owns the brightness value**. No hard-coded restoration level is used.

Ownership rule: a system brightness notification differing from the app-applied value
by more than 0.005 relinquishes restoration for the rest of that dim session, even if
the user later chooses the dim level again. Restoration also compares the current
value with the app-applied value, protecting a newer setting even if its notification
has not arrived. An external change to exactly the same value is indistinguishable
from an app notification and does not relinquish ownership. A new explicit dim action
starts a new ownership session. Opening Control Center normally deactivates the scene,
so brightness is restored before the user makes their adjustment there. Returning to
the app neither resumes capture nor re-enters dim mode automatically.

Dim mode does not change capture or idle-timer policy. The existing app lifecycle stops
capture outside the foreground; interruptions require explicit Start to resume.

## Battery observation

`DeviceBatteryMonitor` subscribes to battery-level and battery-state notifications
only while the active camera UI is shown, reads once on activation, and removes both
observers on deactivation/deinitialization. There is no timer or polling task. It
temporarily enables battery monitoring and restores its prior enabled setting.
Negative, nonfinite, or out-of-range levels display **Battery level unknown**; unknown,
unplugged, charging, and full power states have explicit text. Percentage describes the
whole device and is not an estimate of this app's energy use.

## Verification

Added `DimBatteryTests` for explicit activation, one snapshot, repeated activation/wake,
every nonbuffering capture exit (including failed start and interruption/pause), shared
library/disappearance/inactive cleanup, no automatic dim on return, unchanged buffering
during saves, unavailable scene, already-low brightness, notification and unnotified
external changes, deinitialization, unknown/charging/full readings, notification removal,
and preservation of a prior battery-monitoring owner.

Added `DimRecordingUITests` for touch save/wake without volume input, recording/ready
and battery text, success while remaining dimmed, background returning to paused normal
UI, and reachable controls at accessibility XXXL. The dim view uses a scrollable layout,
white-on-black content, text status (no reliance on color), descriptive labels/hints,
VoiceOver focus on status, and an accessibility Escape action to wake.

Native runs `44121676033` and `44121740447` exposed a test-navigation failure at
accessibility XXXL before dim mode opened: `bufferButton` existed, became hittable
but only partly visible, and subsequent full upward swipes passed it. The dim UI
test now uses bounded, bidirectional drags toward the viewport center while retaining
the full-frame containment and hittability requirement. It logs control geometry and
attaches the accessibility hierarchy to make any remaining layout failure reviewable.
The XXXL case also performs the touch save, checks completion, wakes, and verifies
that buffering continues. This follow-up still requires a native CI rerun; the Linux
workspace cannot execute XCUITest.

Local verification: `git diff --check` and source privacy validation. This Linux
environment has no Xcode/iOS SDK; XCTest/XCUITest compilation and execution must run
in the integrated macOS CI after project regeneration. This branch's focused
`CameraView` integration requires issue #4's `canSave` and `saveStatus` APIs. No iPhone
measurements or physical accessibility checks have been performed.

## Post-roll integration (#10)

Apply the post-roll model implementation before the dim countdown follow-up: the
camera view passes issue #10's optional `CameraModel.postRollRemaining` into
`DimRecordingView`. While a save is collecting more media, dim mode exposes the
same rounded-up remaining seconds as the normal camera screen, with a readable
label, VoiceOver value and `dimPostRollStatus` identifier. The countdown disappears
when collection finishes; the save label continues to cover export and lease release.
It does not move accessibility focus or announce every media-time update.

Preserve the integrated thermal startup guards, callback-generation fencing,
`!saving` in start/preference readiness, global save banner, and dim brightness
lifecycle hooks when merging issue #10's older model/view context. Check countdown
visibility and VoiceOver values at large Dynamic Type during a physical post-roll
save, then verify thermal stop/background/library navigation still restore brightness
and report either a completed, explicitly shorter, or failed save. Those native and
physical checks remain pending.

## Physical iPhone checklist — pending

- iOS 17.0/17.1 touch-only operation, and a newer supported iOS: explicitly start,
  dim, save repeatedly, verify saved media and success, wake, stop, open library.
- Set a distinct brightness before dimming; verify exact restoration on wake, Stop,
  library, incoming call/capture interruption, Home, lock, and app termination/relaunch.
  Verify no other app is left at the app-applied dim level.
- While dimmed, adjust brightness in Control Center; verify the chosen setting is
  preserved when returning, waking, and stopping. Verify repeat dim takes a new snapshot.
- Leave buffering/dim mode active in foreground to check existing idle prevention;
  background/lock and confirm capture pauses and requires explicit restart.
- Plug/unplug power, reach full charge where practical, and observe battery text updates;
  check unavailable readings on Simulator. Verify observation ends in library/background.
- VoiceOver: status focus, ready seconds, battery text, Save, Wake, two-finger Escape;
  XXXL text and smallest supported iPhone: all controls scroll into view, no truncation,
  usable targets/contrast at the actual dim brightness.
- If energy effects are evaluated later, use a controlled physical-device measurement
  protocol. This change makes no measured energy-saving or battery-drain claim.
