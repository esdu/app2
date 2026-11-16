# Production recorder harness (#2)

## Boundary and invariants

`CaptureEngine` still owns permissions, foreground/start-request cancellation,
session configuration, interruption routing, and the periodic health timer.
Its hardware delegate forwards samples to `RollingRecorder.ingest`. The recorder
owns the real `SegmentWriter`, `SegmentIndex`, two-second rollover, asynchronous
finalization, generations, snapshot leases, disk guards, statistics, and watchdog.
There is no alternate recorder implementation in the synthetic test path.

Recorder synchronous operations belong to its supplied serial queue. Its stable
operations are `start(audio:duration:)`, `stop(snapshotError:)`,
`ingest(_:isAudio:)`, `pollHealth()`, asynchronous `snapshot()` and `release(_)`.
`now` supplies monotonic host time independently of each sample's media PTS.
Constructor factories/callback delivery and free-capacity injection support
deterministic failure/delayed-finalization tests without changing normal policy.

The hardware path never sleeps or polls encoder readiness. `SegmentWriter.append`
returns false on backpressure before consuming the per-stream timestamp. The
DEBUG-only `appendManually` retries off the capture queue with a 15-second default
deadline; cancellation and writer-overload pacing are bounded. No application
factory or simulator detection selects `TimestampedSampleSource`. It is explicitly
constructed only in tests. Normal simulator launch still uses `CaptureEngine`.

The existing 160 MiB completed-segment bound, 192 MiB aggregate capture-file
guard, 64 MiB free-space floor, three-finalization overload stop, five-second
video watchdog, complete file protection, backup exclusion, generation cleanup,
source leases and staged persistent library publication remain in force. Save
still briefly freezes ingestion while finalization completes; removing that gap
belongs to #11 rather than being hidden by this harness.

## Coverage and selectors

Run `LittleMomentsTests/RollingRecorderTests` in the ordinary Debug simulator test
plan. The eight `testFiveMinuteRetention{15,30,60,120}Seconds{Silent,Audio}` methods
each advance **300 seconds of logical media**, encoding 600 identifiable frames
through the actual recorder. They assert retained source ranges, actual file
sizes/sets, quotas, expiration, leases through stop/export, decoded exported frame
IDs/counts/PTS, PCM tone markers/continuity and final cleanup. Low-resolution
128x96 video at 2 fps bounds CI cost; it is not a 720p30 performance measurement.

Additional tests cover:

- `testRolloverAndRepeatedSnapshotsPreserveFrameMarkers`: actual 30 fps, warmup,
  before/after rollover, nonboundary/repeated saves, concurrent feed/export,
  decoded source frame IDs and identifiable decoded PCM.
- `testOffsetAudioAndIntentionalGapKeepIdentifiableContent`: positive audio offset,
  explicit timestamp gaps, decoded ordered audio/video and non-silent markers.
- `testLeaseSurvivesEvictionDuringLibrarySave`: real asynchronous library save,
  capture continues past source expiry, release removes old files, committed clip
  survives buffer stop and library reload.
- `testDelayedCompletionCannotCrossGeneration`,
  `testStopDuringPendingSnapshotSettlesOnceAndRequiresExplicitRestart`: genuine
  encoded files with delayed callback delivery, cancellation, stale generations,
  exactly-once continuation settlement, explicit restart and eventual file cleanup.
- `testBoundedPendingWritersStopOnOverload`,
  `testManualEncoderWaitIsBoundedAndRealTimeIngestionNeverWaits`,
  `testWatchdogUsesHostClockAndNeverRestarts`,
  `testLowDiskAndWriterFailureStopWithoutLeakingFiles`.
- `testLibraryFailureRemovesStagingAndLeaseCanBeReleased`: source/export failure
  after production leasing, real library staging cleanup and lease release.

Existing `CameraModelTests` remain the lifecycle layer for backgrounding,
interruption and cancellation during suspended permission/startup. The new recorder
tests exercise the corresponding production stop boundary with pending media.

For bounded stress repetition select
`LittleMomentsTests/RollingRecorderTests/testRolloverAndRepeatedSnapshotsPreserveFrameMarkers`
and
`LittleMomentsTests/RollingRecorderTests/testDelayedCompletionCannotCrossGeneration`.
On failure the suite attaches media files and decoded timing/source-range logs to
the xcresult before removing its temporary directory. The CI diagnostics task owns
xcresult/artifact retention and the bounded repeat selection.

## Validation and remaining acceptance

The Linux editing environment has no Swift compiler, Apple SDK or iOS simulator.
`git diff --check` and the source privacy-manifest validator were run locally;
**these XCTest methods have not been executed here**. Parent integration must add
new Swift files with the repository project generator and run the required macOS
simulator build/test, built-app privacy check and unsigned Release archive check.
The decoded assertions are acceptance checks to run, not preclaimed evidence.

Physical-device acceptance remains pending: actual 720p30 audio/video cadence,
front/back orientation, microphone format negotiation, interruption/background
delivery, protected-data behavior, encoder pressure, storage exhaustion, thermal
and battery cost. Simulator success cannot establish camera performance. Negative
audio offsets and alternate pixel formats can be supplied by this source and
should be extended by #8/#9 measurements; the committed offset case is positive.
