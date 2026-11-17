# Actual-resolution software checks for #12

`LittleMomentsTests/QualityResolutionRecorderTests` extends the production A/V
harness with **720×1280 and 1080×1920 portrait NV12 samples**, using the real
`RollingRecorder`, `SegmentWriter`, index/leases, MP4 composer and system codecs.
The fixture exists only in the test target. Capture formats, settings, bitrate,
production defaults and the [1080p30 no-go decision](ISSUE_12_QUALITY_FEASIBILITY.md)
are unchanged.

Three short test methods bound CI cost:

- Each resolution runs independent 0.5-second early save, 2.0/2.5-second saves
  immediately around natural two-second rollover, and an 18.5-second run whose
  export trims an interior non-keyframe to the full 15-second window. Independent
  starts prevent an earlier snapshot from moving the tested rollover boundary.
  The latter must decode exactly source frame IDs 7–36 at output PTS 0–14.5s.
- A stopped 720→1080→720 restart sequence retains each old snapshot lease while
  starting the next run with the **same media timestamps**, different frame IDs
  and audio on/off/on. Each export must contain only its own generation's IDs,
  dimensions and audio intent; old leased files survive until release and all
  capture files disappear afterward.
- Every export is decoded for all frame IDs/counts/PTS, actual portrait dimensions,
  asymmetric orientation marks, audio presence, decoded PCM tone identity,
  continuity and A/V start/end alignment. Assertions check real source boundaries
  and cleanup, not just playable output. A retained attachment records dimensions,
  decoded IDs, durations, audio presence and bytes; failing media is attached.

These tests encode **112 source frames total at 2 fps**, rather than a repeated
full-resolution 30 fps retention matrix. Run them once in the ordinary test pass;
do not add them to the narrow repeated stress selection. Regenerate the Xcode
project with `python3 scripts/generate_project.py` before native execution.

## What remains pending

The Linux editing environment has no Swift compiler, Apple SDK or simulator.
Only source review and `git diff --check` have run here. The three XCTest methods
have **not** been compiled or executed; native CI must establish real-codec results
and retain its xcresult evidence. Their inclusion is software coverage, not a pass.

A successful simulator run would establish only the exercised encoder/recorder
correctness at these dimensions and 2 fps. It would not establish camera format
support, sensor rotation, sustained 30 fps, 1080p visual quality at the current
bitrate, peak memory/storage, thermal/energy cost, or physical device support.
The stopped restart test covers recorder generation isolation; there is still no
quality preference or requested/effective capability-fallback implementation to
test. Both audio-offset variants and all four full-resolution retention windows
are not multiplied here; existing smaller-fixture suites cover broader timing and
retention while the physical/expanded acceptance remains explicitly tracked.

The exact device/OS/build/camera capability ledger, sustained longest-window
audio on/off/repeated saves, measured resource bounds, low-storage/system-pressure
and hardware quality/orientation checks in #12 remain pending. A future quality
implementation also needs stopped-only settings and capability/fallback tests.
This supplement completes neither #12's full acceptance nor permission to enable
1080p30. Production remains 720p; 4K/60 fps remain deferred.
