# Validation evidence

The implementation is being validated by GitHub-hosted macOS CI. Consult the latest run linked from the README badge for authoritative build/test status and downloadable artifacts.

- Local development workspace: Linux; Xcode/iOS SDK are unavailable here.
- Physical iPhone capture, thermal/storage soak, and accessibility acceptance: **not executed**.
- Test implementation uses real system video/audio encoders and decoders for media integration tests, and a separate opt-in DEBUG simulator camera for UI workflows.
- Production camera capture is AVFoundation-based and is never replaced automatically by mock data.

Final CI run and observed test counts will be recorded after the workflow completes.
