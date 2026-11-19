# Deferred features and gated assessments

Implemented preferences, feedback, dim/battery, public capture-button interaction, thermal policy and opt-in Off/5/10 post-roll are described in the [README](../README.md) and [acceptance ledger](ISSUE_ACCEPTANCE_LEDGER.md). Their physical checks remain pending. Capture stays local, foreground-only and explicitly restarted after interruption.

| Feature | Current decision and remaining gate |
| --- | --- |
| On-device voice save | **Deferred** after the [feasibility assessment](ISSUE_13_VOICE_FEASIBILITY.md). No speech permission or recognition is enabled. A later opt-in prototype needs actual locale/device support, on-device-only enforcement, bounded audio work, stale-task protection and measured reliability/energy. |
| Continuous snapshot replacement | **No-go for adoption**. The [DEBUG continuous MOV experiment](ISSUE_11_CONTINUOUS_SNAPSHOT.md) has comparative correctness tests, but no device-energy comparison or hard combined capture/export staging budget. Production Off retains the established snapshot path. |
| Passthrough export default | **Unchanged**. The [internal MP4 evaluation](ISSUE_9_EXPORT_EVALUATION.md) retains highest-quality export as default until device/consumer correctness and performance gates pass. |
| 1080p30 selection | **No-go pending evidence**. [Budget/capability assessment](ISSUE_12_QUALITY_FEASIBILITY.md) and actual-resolution codec tests do not establish 30 fps device throughput or sustained retention/storage/thermal bounds. No runtime preset is exposed. |
| 4K or 60 fps | Separately deferred; capability enumeration alone cannot justify memory, encoder, retention, power or thermal support. |
| Other hands-free triggers | Future local gestures or explicit external accessibility/switch controls need an armed state, false-trigger protection, manual fallback and measured power. Public capture-button support is already implemented; no private volume interception is proposed. |
| Apple Watch companion | Future explicit requests to an actively buffering foreground iPhone need reachability, acknowledgment and stale-state handling. A suspended or locked iPhone cannot promise camera capture. |

Other candidates include thumbnails, an explicit saved-library warning threshold without automatic deletion, landscape support and a broader physical accessibility matrix. Keep each proposal scoped and gated by measured evidence.
