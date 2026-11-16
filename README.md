# Little Moments

[![iOS CI](https://github.com/esdu/app2/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/esdu/app2/actions/workflows/ios-ci.yml)

Verified simulator build: **28 unit/integration tests and 5 UI tests passed**, zero failures. [Successful run and artifacts](https://github.com/esdu/app2/actions/runs/43955515633) · [Validation details](docs/VALIDATION.md). Physical iPhone testing remains outstanding.

A local-first iPhone camera for keeping the moment just before you tap **SAVE MOMENT**. Requires iOS 17+. Start a short rolling buffer, stay present, and save a spontaneous moment to a private local clip library.

**Foreground only.** Locking the phone, leaving the app, interruptions, or opening the clip library stops capture. Return and explicitly tap **Start Buffer** to restart. This app is not a baby monitor or a substitute for direct parental supervision.

## Features

- Native SwiftUI camera preview, rear/front camera selection, microphone toggle, and explicit start/stop.
- 15, 30 (default), 60, or 120 seconds of retrospective video.
- H.264 video and optional AAC audio in two-second compressed MOV segments.
- Prominent save button, buffer status, duration, and approximate temporary storage display.
- Trimmed MP4 export into an independent persistent local library.
- Playback, system share sheet, optional add-only Photos export, and confirmed deletion.
- Foreground and interruption handling with no automatic recording restart.
- Dynamic Type, scrolling for smaller screens, accessible control labels, and VoiceOver status.
- No runtime third-party dependencies, accounts, ads, analytics, or video networking.

## Build and run

1. Clone this public repository on a Mac with Xcode 16+ and an installed iOS 17+ simulator runtime.
2. Open `LittleMoments.xcodeproj`. The project and shared `LittleMoments` scheme are checked in; no generator or package installation is required.
3. Choose the `LittleMoments` scheme and an iPhone simulator, then Run. A simulator cannot supply a production camera.
4. For an iPhone: select your own signing team in the application target, choose your phone, and Run. A personal development team can be used subject to Apple's device-install limitations. Simulator CI needs no signing credentials.
5. Tap **Start Buffer**, grant camera/microphone access, and wait for the buffer. System permission dialogs may make the app inactive; if so, explicitly tap Start Buffer again after granting permission. Disable audio before starting if you do not want microphone access.
6. Tap **SAVE MOMENT**. The first clip may be shorter than the selected duration while the buffer warms up. Opening the library stops and clears the expendable buffer, but never deletes saved clips.

Camera, audio, and duration can be changed while stopped. Camera switching deliberately requires stopping first, keeping orientation and audio configuration consistent within a buffer. The MVP records portrait 720p H.264 (4 Mbps target), AAC mono audio when enabled.

## Architecture

| Component | Responsibility |
| --- | --- |
| `CaptureEngine` | Serial AVFoundation configuration and sample delivery, foreground stop, camera interruption handling, bounded writer count |
| `SegmentWriter` | Real-time H.264/AAC encoding, per-stream monotonic timestamp validation, shared capture-clock session |
| `SegmentIndex` | Ordered metadata, duration/byte eviction, leases protecting files during save |
| `ProtectedFiles` | Protected directories, file size accounting, expendable-file deletion |
| `ClipComposer` | Trim source ranges, align audio, join segments, export playable MP4 |
| `ClipLibrary` | Staged export, atomic rename, persistent clip enumeration, user-directed deletion |
| `Permissions` | Camera/microphone permission on start; Photos add-only permission on export |
| `CameraModel` | Main-actor UI state, lifecycle, operation tokens preventing late startup after backgrounding |
| `SyntheticCamera` | DEBUG-only opt-in simulator fixture; never the default camera |

### Rolling storage and save consistency

No frame history is retained in memory. Capture callbacks receive frames on one serial queue, use real-time encoder backpressure, and discard late video frames. Only short compressed files and segment metadata form the rolling history. Writers finish asynchronously, with at most three in flight; encoding overload stops capture instead of accumulating work. A monotonic-clock watchdog stops capture if video frames stop arriving for five seconds, even if audio is still flowing.

Completed segments expire once wholly outside the selected duration. One segment may straddle the boundary (up to two seconds); export trims this precisely to the requested range. Completed segment storage is limited to **160 MiB**. All buffer-directory files, including active and finishing writers and pinned segments, are checked every 250 ms of incoming audio or video against a **192 MiB safety threshold**; less than 64 MiB available device storage also stops capture. As with filesystem quotas implemented at application level, the physical byte threshold can be exceeded briefly between checks by encoder output; the amount of queued work and file count remain bounded. Filesystem failures surface to the user. These limits apply to temporary capture files; saved clips consume storage until the user deletes them.

Save freezes sample intake briefly while the current segment and any pending segments finalize. It captures the trigger cutoff, pins the selected segments before eviction, then immediately resumes buffering during composition. There can be a short gap after a save while finalization completes. Production timestamps remain on one capture clock; source audio is intersected with the video range and inserted at its original relative offset. Gaps between source segments are collapsed. A single save runs at a time.

The composer writes a protected staging file into `Application Support/SavedClips`, then renames it to `.mp4` only after success. Rolling-buffer eviction cannot touch it. Startup cleans abandoned staging files and the separate rolling cache, preserving completed clips. Export failure leaves the source lease intact until cleanup; completed saved clips are never automatically removed.

## Tests

Run Product → Test in Xcode, or on a Mac:

```sh
SIMULATOR_ID=$(python3 scripts/select_simulator.py)
xcrun simctl boot "$SIMULATOR_ID" # skip if already booted
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild test -project LittleMoments.xcodeproj -scheme LittleMoments \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -resultBundlePath build/LittleMoments.xcresult CODE_SIGNING_ALLOWED=NO
```

- Policy unit tests cover all duration choices, boundary eviction, byte caps, ordering, overlapping save leases, stop cleanup, invalid timestamps, and permission/interruption state.
- Media integration tests encode real H.264/AAC fixture data, trim and concatenate it, decode exported video with `AVAssetReader`, verify A/V timing, reload saved files, and test deletion/crash cleanup.
- Model tests verify no capture at launch, denied access, foreground/background behavior, interruptions, and visible save errors.
- XCUITest covers launch, duration selection, start/stop, saving, playback, library navigation, deletion, denied permission, and explicit restart after backgrounding. Every UI test keeps screenshot and accessibility-hierarchy attachments. Synthetic buffer statistics stay fixed at the actual two-second fixture duration, avoiding continuous UI updates during XCTest idle checks.

UI tests pass `--uitesting` in DEBUG to select an explicitly labeled synthetic camera and isolated disposable library. This generates a deterministic two-second movie with system codecs and exercises the real composer and library. A normal launch always uses `CaptureEngine`, even in the simulator. Release builds exclude the synthetic implementation. Simulator testing does **not** validate physical camera capture, thermal behavior, microphone hardware, optical stabilization, or real-world interruption timing.

## GitHub Actions

`.github/workflows/ios-ci.yml` runs on main pushes, pull requests, and manual dispatch using standard GitHub-hosted `macos-15-intel`. It records the runner's selected Xcode, discovers an available iPhone dynamically from installed iOS runtimes, resolves dependencies (currently none), compiles the app and both test targets, then runs all tests without signing.

CI also validates the source and built app privacy manifests, creates an unsigned Release archive for a generic iOS device, and checks the manifest inside that archived app. The archived manifest and validation logs are included in the artifacts. This checks packaging without Apple signing credentials; it does not replace signed distribution validation in Xcode Organizer.

Compilation, test, archive, or privacy validation failure fails the job. Per-test execution timeouts are enabled (120 seconds default, 180 seconds maximum); a timeout fails the test rather than skipping it. Synthetic encoder readiness waits also have an explicit deadline. `ios-results-*` artifacts are uploaded even on failure and retain build/test logs, the `.xcresult` bundle, test screenshot attachments when available, a final simulator screenshot, and app logs for 14 days. Download artifacts from the workflow run page. Open `.xcresult` in Xcode to inspect test details. No Apple certificates, provisioning profiles, paid third-party services, or cloud infrastructure are configured. This standard Intel label avoids the ARM64 capacity failure observed during development; it is not a larger paid runner. Repository/org Actions policies must allow the standard GitHub actions and macOS runners.

The project generator is optional: after adding Swift files, run `python3 scripts/generate_project.py` and commit the updated project. It uses only Python's standard library.

## Privacy

Video and audio stay on-device. Camera access is requested only on an explicit start; microphone access only when audio is enabled; Photos add-only access only on export. No network client, background capture mode, account system, advertising, or analytics is included. System share and Photos exports occur only when chosen by the user. The system camera/microphone indicators and in-app status show active capture.

Buffers and clips use complete iOS file protection and are excluded from backup. Saved clips survive app restarts but **not app deletion**; export irreplaceable clips. Cache files are disposable and cleaned at startup. The privacy manifest declares app-owned file timestamp access (`C617.1`), disk-capacity checks (`E174.1`), and System Boot Time access (`35F9.1`) for the watchdog and storage-check intervals. Uptime is used only for elapsed-time calculations inside the app. [Privacy declaration and archive validation](docs/PRIVACY_VALIDATION.md). Exported Photos items and copies shared to other apps follow those apps' storage policies.

## Known limitations and physical testing

- Hardware camera/microphone testing must be completed on an iPhone; no such testing is claimed by simulator CI.
- Portrait, fixed 720p/4 Mbps H.264, wide-angle front/rear camera only. No zoom, lens selection, background capture, Watch app, voice trigger, volume-button interception, or post-trigger recording.
- Start again after interruptions, backgrounding, device lock, permission prompts that interrupt startup, or visiting the library. Unsaved buffer content is expendable.
- Save may briefly interrupt incoming frames during segment finalization. Low-resource encoders can drop late frames or stop with a visible error.
- Saved clips have no automatic size quota; low disk space may prevent save. Delete unwanted clips or export them manually.
- Export can fail if the phone locks during file access under complete file protection. The operation reports an error; a successful background export is not guaranteed.
- Dynamic Type and VoiceOver are implemented with standard controls but still need physical accessibility review.

Use the [physical iPhone checklist](docs/PHYSICAL_TESTING.md), [test evidence](docs/VALIDATION.md), and [future roadmap](docs/ROADMAP.md) before shipping.
