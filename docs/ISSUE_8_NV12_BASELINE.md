# Issue #8: supported NV12 output and explicit 30 fps baseline

## Effective capture configuration

`CaptureEngine.configure` remains on the existing capture queue. It enumerates the
selected front/rear wide-angle camera's formats and both bounds of every advertised
frame-rate range. `CaptureFormatPolicy` selects 1280×720 when supported at exactly
30 fps; otherwise it selects the largest supported format with width ≤1280 and height
≤720 at 30 fps. Ties use stable device-format order. Formats whose minimum exceeds
30 or maximum is below 30 (including 29.97) are rejected. No higher resolution or
higher/lower frame-rate option is introduced.

The session uses `.inputPriority` so the chosen format controls resolution. Under
`lockForConfiguration`/deferred unlock, capture sets `activeFormat` and both active
frame durations to 1/30 second, then verifies both read back exactly. After adding
the video output, it queries that output's supported pixel formats and requests,
in order, NV12 full range, NV12 video range, or deliberate BGRA fallback. It requires
the existing 90° portrait output rotation; the preview already uses the same angle.
Unsupported format/rate/pixel type/rotation produces an actionable startup error
suggesting camera switching and explicit retry. Microphone configuration is unchanged.

`CaptureDeliveryValidator` checks each actual video sample's image and format-description
dimensions, pixel subtype, finite and increasing presentation timestamps, and minimum
frame spacing. Expected portrait dimensions are the selected native height×width.
Intervals faster than 30 fps beyond 3 ms tolerance stop buffering with an explanation;
slower delivery/dropped frames are accepted and reported accurately. A fresh validator
and drop counter are created for every start and cleared on stop, including failure.

OSLog category **CaptureConfiguration** records the selected camera, native dimensions,
fixed requested frame rate, rotated dimensions, and selected pixel format. It records
first delivered dimensions/type, measured delivered cadence every 150 frames, and
delegate drop counts at the first drop and each additional 30 drops. Before two frames
there is no measured cadence (`pending`). Delivered cadence includes gaps and is not
a claim that every frame arrived at the requested rate. These logs contain configuration
and counters, not image/audio content. BGRA or smaller dimensions explicitly identify
a supported fallback. No per-frame log is emitted.

`SegmentWriter` receives the original bi-planar sample without an app-level RGB
conversion. Its source format hint preserves the input subtype/range and it propagates
present source color-primaries, transfer-function, and YCbCr-matrix properties into
encoder settings. It does not fabricate missing color metadata or label video-range
samples as full range. Encoder bitrate/keyframe baseline stays unchanged.

## Verification and limits

The branch is based on issue #2's production `RollingRecorder` seam (4e86182). Added:

- Six policy/delivery tests covering both frame-rate bounds, multiple rate ranges,
  deterministic 720p selection, smaller-only fallback, unsupported combinations,
  NV12 full/video/BGRA preference, actual portrait dimensions/subtype/timestamp/cadence
  rejection, dropped-frame gaps, and fresh state after a camera change/start.
- Four real-codec harness scenarios: full-range/video-range NV12 × audio enabled/disabled.
  Portrait 96×128 bi-planar fixtures include propagated BT.709 tags, eight saturated
  color bars, frame identity, and timestamped PCM from the issue #2 source. Samples
  traverse production `RollingRecorder` → `SegmentWriter` → snapshot leases →
  `ClipComposer` → BGRA decode. Three repeated saves cross two-second rollovers.
  Assertions check pixel subtype/planes/tags before ingestion, exported dimensions
  and portrait transform, color channels/range (30-code-value codec tolerance), every
  frame marker and 30 fps PTS, audio presence/timing, decoded nonsilent PCM, and cleanup.

The fixture is already portrait, modeling the capture connection's delivered output;
it does not exercise physical sensor rotation. Synthetic tests do not establish which
formats a physical camera advertises or how that device performs. Existing recorder
tests remain the gate for A/V retention, quota enforcement, backpressure, watchdog,
leases, interruption cleanup and protected persistent saves; those mechanisms are
unchanged by this ticket.

Local `git diff --check` and source privacy validation pass. This Linux environment
has no Xcode/iOS SDK. SDK compilation, XCTest/XCUITest and unsigned archive validation
must run in integrated macOS CI after project regeneration. No physical measurements
have been performed, and no CPU, memory, energy, thermal, or long-session improvement
is claimed from the nominal 1.5-versus-4 bytes/pixel comparison.

## Physical front/rear verification — pending

Record device model, iOS version, build/commit, camera position, audio state, selected
configuration log, and test duration for each run. Preserve logs/media in CI artifacts
or an explicitly chosen local measurement folder; do not upload personal recordings.

1. On each camera with audio off and on, Start/Stop repeatedly and switch cameras
   between stops. Capture first-frame and interval logs: actual format, dimensions,
   measured cadence, delegate drops. Confirm no stale configuration or automatic restart.
2. Use a color/gray reference target and upright orientation target. Save before/after
   rollovers and repeatedly during a longer foreground session. Inspect exported color,
   legal/full-range appearance, portrait dimensions/orientation, and audio alignment.
3. Background/lock, interrupt with a call/camera conflict, deny permission, and retry
   explicitly. Verify capture pauses and the next start selects/validates a fresh format.
4. Exercise a camera/output lacking preferred NV12 or fixed 720p30 when available;
   verify documented smaller/BGRA fallback or actionable unsupported-start error.
5. Compare BGRA and NV12 only at equivalent supported 720p30/audio/scene/brightness
   settings on the same physical device. Use controlled duration, Instruments/energy
   and thermal observations, CPU/memory and dropped-frame measurements, and repeated
   saves. Keep diagnostic comparison configuration out of the production user flow.
   Establish long-session stability and report measured results before claiming gains.
