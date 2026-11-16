# MP4 passthrough evaluation (#9)

## Decision: retain highest-quality export by default

`ClipComposer()` continues to use `AVAssetExportPresetHighestQuality` and MP4. The internal `.evaluatePassthrough` strategy is available only to explicit callers such as the evaluation tests; no app setting, launch path, or production save call enables it. There is no hardware performance evidence for changing the default. A compatibility check is necessary but cannot prove accurate edit-list trims, decoded content, Photos/share interoperability, or energy savings.

## Implementation

The existing composition's video/audio intersection, common-clock translation, gap collapse, preferred transform, and file protection remain intact. Production saving still leases sources in the camera/model and commits the protected staging file through `ClipLibrary`'s atomic rename. The exporter neither releases a snapshot nor removes a source segment.

The trial first asks AVFoundation about passthrough compatibility with MP4. Unsupported combinations go directly to highest quality. Each attempted export creates a new `AVAssetExportSession`, also checks `supportedFileTypes`, and disables network optimization as before. Only an explicit unsupported session/output combination or `AVError.operationNotSupportedForAsset` permits a retry. Cancellation, full disk, protected-data/access failures, generic `exportFailed`, and unclassified errors propagate. A causal error under an unsupported-operation wrapper must also qualify; filesystem errors cannot be hidden by that wrapper. Before retrying, the failed destination is removed with a throwing operation. Failure/cancellation at either attempt removes the destination. Successful export is protected before returning to the library for publication.

Task cancellation now calls `cancelExport`, checks cancellation before and after an attempt, and never starts a fallback for cancelled work.

## Automated correctness and measurement matrix

`ClipExportTests` has seven deterministic checks for the unchanged default, unsupported passthrough, failed-first-output cleanup, fallback failure cleanup, cancellation/storage/access errors, an already cancelled task, and narrow error classification. A real `SegmentIndex` lease remains pinned throughout both injected export attempts and is released only by its owner afterward. These are export-boundary test doubles; the application always uses the system backend.

`ClipExportContentTests` has five real-codec cases based on issue #2's `TimestampedSampleSource`, production `SegmentWriter`, and `RollingRecorder`:

- Independent H.264 segments with distinct files, nonzero capture-clock origins, silent and identifiable nonsilent AAC paths, both strategies.
- Requested first/last source content at non-keyframe and between-frame trims (.35–3.85 seconds); binary decoded frame IDs detect earlier preroll or a missing tapped moment. Tone frequency and RMS detect silent or misplaced audio.
- Delayed audio and a deliberate source-clock gap: every decoded frame remains ordered, the join collapses the gap, and identifiable audio stays synchronized on both sides.
- Rear portrait and mirrored front portrait metadata on real encoded media: display dimensions and a rendered marker grid match the source, whether an exporter preserves metadata or bakes transforms into pixels.
- Early save and full 15/30/60/120-second windows, repeated exports while the real recorder continues ingesting. Decoded first/last/all frame IDs and audio frequencies verify each selected window; leased source files must survive concurrent capture.

Every content test retains an XCTest attachment named **Export trial wall time, bytes, and decoded endpoints**. It records requested strategy, compatibility result, actual preset attempt sequence, wall time, output bytes, decoded endpoints, and (for the window matrix) rolling-disk bytes, segment count, and pending writer count. A trial that fell back is labelled by its actual attempts and must not be presented as a successful passthrough measurement. Failed tests also attach media for inspection.

## Results and limits

| Evidence | Status |
| --- | --- |
| Source privacy validation | Passed locally on Linux |
| `git diff --check` | Passed locally |
| Swift compilation / real-codec simulator matrix | Pending macOS CI; no Xcode or Apple frameworks in this Linux environment |
| Simulator timings / bytes | Pending retained XCTest attachments; no invented numbers |
| Physical iPhone early/full/repeated-save benchmarks | Pending |
| Device encoder pressure, dropped frames, thermal state and energy | Pending |
| MP4 Photos export and share-sheet consumers | Pending device checks; existing app paths unchanged |
| Front/rear physical camera portrait playback | Pending; automated metadata fixture is not a physical camera pass |

Use the existing macOS simulator test run with selectors `LittleMomentsTests/ClipExportTests` and `LittleMomentsTests/ClipExportContentTests`, together with `RollingRecorderTests` and `MediaIntegrationTests`. Record actual CI numbers before comparing strategies. Simulator throughput and the accelerated 128×96 fixture do not establish device speed or energy benefits.

On physical iPhones, record model/iOS, battery/thermal state, audio on/off, early save plus all four durations, repeated saves with capture active, actual export strategy, elapsed time, bytes, dropped frames/encoder pressure, and Instruments energy/thermal observations. Decode marker/known content at both endpoints and joins, then exercise playback, Photos, sharing, relaunch/reload and deletion. Keep the snapshot lease through every export attempt. Do not enable passthrough by default until content, interoperability and device measurements all justify it. A non-keyframe endpoint failure is a no-go even when nominal duration is correct.

## Apple API references

- [AVAssetExportPresetPassthrough](https://developer.apple.com/documentation/avfoundation/avassetexportpresetpassthrough)
- [AVAssetExportSession](https://developer.apple.com/documentation/avfoundation/avassetexportsession), including `determineCompatibility(ofExportPreset:with:outputFileType:completionHandler:)`, `supportedFileTypes`, and `cancelExport()`
- [AVAssetReader](https://developer.apple.com/documentation/avfoundation/avassetreader) for decoded sample inspection
- [AVAssetImageGenerator](https://developer.apple.com/documentation/avfoundation/avassetimagegenerator) for preferred-transform display checks
- [AVMutableCompositionTrack](https://developer.apple.com/documentation/avfoundation/avmutablecompositiontrack) for time-range insertion and preferred transforms
