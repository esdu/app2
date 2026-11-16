# Deferred features and feasibility

The MVP keeps capture and export local and foreground-only. No item below is claimed implemented.

| Feature | Feasibility and implementation approach |
| --- | --- |
| Offline “Save recording” | Speech framework requires separate speech permission, locale/device availability, `supportsOnDeviceRecognition`, and `requiresOnDeviceRecognition = true`. Verify actual on-device support at runtime and on each target device/locale; never silently use server recognition or claim universal offline support. Feed a bounded audio stream alongside capture, handle interruptions and recognizer task duration limits, and measure power/false triggers. Unsupported devices/locales should show unavailable. |
| Hands-free triggers | Consider local Vision gesture recognition on sparsely sampled frames or explicit external accessibility/switch controls. Require an obvious armed state, false-trigger protection, battery measurements, and manual save fallback. No private volume-button interception. |
| Apple Watch companion | WatchConnectivity can send an explicit save request to the actively buffering foreground iPhone. Display reachability/acknowledgment and stale-state handling. Watch cannot guarantee camera capture on a suspended/locked iPhone; do not promise remote background recording. |
| Resolution selection | Offer supported session presets and encoder sizes only while stopped. Budget bit rate/storage limits together and benchmark older phones; restart capture on changes. |
| Slow motion | Select supported device `activeFormat` frame-rate ranges and exposure; coordinate playback timing and an audio policy. High frame rates increase thermal load, bandwidth, and storage, requiring fresh bounds and hardware QA. |
| Post-trigger duration | Pin the pre-trigger range, collect a bounded future tail with a cancellation/deadline state, then export on the same capture clock. Stop/background events must offer a partial result or visible failure. Count both pre-trigger pins and future segments within the same disk budget. |

Additional candidates: photo thumbnails, configurable saved-library warning threshold (never automatic deletion), richer interruption diagnostics, landscape support, and hardware-matrix accessibility testing.
