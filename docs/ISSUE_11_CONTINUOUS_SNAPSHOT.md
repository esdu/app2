# Continuous snapshot assessment (#11)

Decision: **NO-GO for production adoption.** Production Off remains the existing
freezing retrospective save. No physical iPhone continuity, energy, thermal,
latency or peak-memory evidence has been collected. The tests below have not run
in the Linux editing environment; simulator results must not be substituted for
the device gates.

## Candidate and baseline

`ContinuousSnapshotExperiment` is DEBUG-only, explicitly constructed by tests.
There is no launch argument, environment switch, camera-service factory change or
Release implementation. Its baseline calls the real `RollingRecorder.snapshot()`;
its candidate calls the shared internal `snapshotKeepingIntake(postRoll: 0)` seam.
That seam is implemented alongside post-roll and requires that change before this
assessment can build. No independent toy recorder or synthetic codec replaces the
production pipeline.

The candidate registers the retrospective interval and pins its boundary before
closing the active MOV writer. Its cutoff is the end of video already accepted at
trigger registration. New samples can enter a new MOV writer while old files
finalize; only finalizers intersecting the registered interval delay delivery.
The exported snapshot never includes the newly arriving frames. Media time fixes
the range; a separate monotonic host deadline bounds finalization waiting. Stop
ends capture immediately but can safely complete an accepted interval; a stalled
finalization fails on its deadline. Old callbacks cannot enter a new generation.

This is an **alternative continuous segmented-MOV snapshot experiment**, not a
single segmented fMP4 writer. There are no init segments, segment-Data handoff,
fragment concatenation, fragment-generation mapping or HLS profile. MOV files
retain their existing generation ownership, keyframe policy and timestamp mapping.
The experiment still creates encoders at ordinary rotations and at save boundaries;
it does **not** establish fewer encoder creations or reduced energy use. Save may
even increase writer churn. A future fMP4 approach must separately prove init/media
generation identity, independently decodable bounded fragments and bounded byte
handoff; none of those properties can be inferred from this experiment.

## Automated evidence to collect

After merging the post-roll seam, regenerate the Xcode project and run
`LittleMomentsTests/ContinuousSnapshotTests` in Debug on a supported simulator.
Run the normal production harness, privacy validator and archive checks too.
The new selectors exercise actual `SegmentWriter`, `SegmentIndex`, leases and
`ClipComposer` with identifiable timestamped source samples:

- `testHardwareIntakeComparisonSeparatesSaveLossFromEncoderBackpressure`: identical
  real-time, nonretrying video/audio arrival sequence while real codec completion
  is held. Baseline expects five Save-discarded samples per stream; candidate
  expects zero. Received, encoded/accepted, Save-discarded and backpressured counts
  are reconciled independently and attached to xcresult. Both trigger outputs are
  fully decoded to ensure the fixed end excludes frames arriving during Save.
- `testAllRetentionWindowsAndConsecutiveMidSegmentSavesDecodeExactCutoffs`: 15, 30,
  60 and 120 seconds, nonzero PTS, truncated warmup, mid-segment triggers, successive
  saves across expiration and intake concurrent with export. Every video frame ID
  and PTS is checked, every audio packet is decoded and checked for continuity and
  endpoint alignment, and stable PCM tone markers identify source time. This uses
  off-queue manual encoder pacing for deterministic content, so does not by itself
  prove real-time encoder throughput.
- `testDelayedFinalizationDeadlineAndStopDoNotLeakOrRestart`: withheld completion,
  monotonic timeout, interruption/stop while saving, eventual callback cleanup,
  zero leases and explicit restart requirement.
- `testStopAfterCutoffCleansFutureAudioBoundaryOnDeliveryOrCancellation`: continue
  video past a future MOV rotation while a fixed-cutoff save is held; omit audio
  so the boundary retains a future writer; stop and either deliver or cancel the
  save. All active, boundary-held and finalizing files must disappear, with no
  leases or implicit restart.
- `testLowDiskDuringPendingSaveCleansFinalizersAndLeases`: a low-capacity stop
  during Save, safe finalization/error settlement, release and eventual file cleanup.
- `testExportFailureRemovesStagingAndReleasesCaptureLease`: actual failed source
  read through production composer, no residual output/staging or leases.
- `testExportDestinationDiskFailureCleansLeaseAndOutput`: real export-backend write
  failure to a missing destination directory with valid source media; no output,
  source leases or capture files remain after release/stop. This is not a physical
  disk-full measurement.

Existing recorder tests remain required for the three-finalization overload limit,
writer failure, lease retention across eviction, cross-generation delayed callbacks,
video watchdog and archive/persistence behavior. The candidate uses those same
implementations; new tests are not a replacement for them.

## Working-set accounting and unresolved bounds

`workingSet(stagingDirectory:)` enumerates actual capture and export-staging files,
without copying media Data or retaining an event history. Capture bytes include
active, in-flight, completed, leased and retired files; index bytes alone are
insufficient. Each capture file is counted once, even if multiple leases reference
it. Separate experiment staging includes incomplete export output and completed
output waiting for publication. The test samples the census during and after
export and checks a fixture-specific total below 192 MiB. There is no fMP4 init or
concatenation staging in this candidate. The census does not accept hard links as
an accounting exemption.

These are **sampled actual sizes**, not a proven high-water mark or a hard limit.
The production 160 MiB completed limit, 192 MiB capture-directory guard, 64 MiB
free-space floor and three-finalizer limit still apply. Leases can prevent pruning;
the capture guard catches aggregate capture pressure on the existing polling
cadence. Export staging lives outside that capture guard. Current production
`ClipComposer` has no streaming output reservation/cap or cancellation-based disk
budget, so the capture-plus-export working set has no independently demonstrated
hard bound. This is a specific no-go gate, not a claim that the candidate satisfies
issue #11's full storage acceptance. A single small exported fixture cannot prove
that bound. Capture and export work/memory peaks also need device measurement.

Before adoption, introduce one aggregate budget covering capture, all active
leases, retained generations, any initialization/concatenation files and export
staging. Reserve bounded export output and enforce its growth with the export
backend; reject work before an exhausted reservation and remove all failed staging.
Bound concurrent exports/admissions, cancellation latency and metadata history.
Repeat delayed-completion, quota-exhaustion and failed-write tests while measuring
maximum occupied bytes, including intervals between polls. Preserve complete file
protection and backup exclusion for every transient file and staged local library
publication. Do not solve pressure by deleting leased sources or weakening privacy.

## Physical comparison and migration gate

Use the same physical iPhone, OS, camera, microphone, 720p30 configuration, retention
window and scene for both modes. Explicitly opt into one mode per DEBUG measurement
run; do not add an automatic production fallback/restart. Record device/OS/build,
mode, source arrival and accepted counts per stream, Save drops, encoder pressure,
trigger PTS/endpoints, decoded missing-frame/sample intervals, trigger-to-snapshot
and trigger-to-persistent-save latency (median/p95/max), writer creations and
finalization latency, and the total number of saves. Compare equal five-minute
runs with no saves and repeated saves, then thermal-steady longer runs. Include
all retention windows, mid-segment triggers, rapid consecutive saves, warmup,
interruption, background/lock, deliberate encoder delay and low-disk failure.

Measure resident/peak memory, CPU, Energy Log/Power Profiler energy, battery/thermal
state and actual maximum aggregate temporary bytes including library staging.
Attach Instruments traces, decoded-content reports and xcresults to the assessment.
No simulator timing, low-resolution fixture throughput or absent Save-drop counter
is energy evidence. No measurements or percentages are claimed here.

Only consider migration when device results show a worthwhile benefit, the
aggregate budget has a hard implementation/test bound, and every correctness,
protection, cleanup and deadline gate passes. Then review one explicit internal
rollout selector, compare it against baseline on hardware, and retain a rollback
path before changing the production Off default. Positive post-roll behavior is a
separate user setting and is not authorization to switch retrospective saves.
A replacement fMP4 design would require its own reviewed migration, rather than
renaming this MOV experiment or claiming its tests validate fMP4 behavior.
