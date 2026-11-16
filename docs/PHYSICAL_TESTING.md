# Physical iPhone acceptance checklist

Status: **not executed**. Simulator success does not complete this checklist.

Record device model, iOS version, build commit, available disk space, test date, and results. Use non-sensitive footage and an adult test subject for initial engineering verification.

1. Fresh install: no camera indicator, permission dialog, or capture before Start Buffer. Deny camera, verify explanation and Settings route. Grant it and explicitly restart. Disable audio and verify microphone permission is not requested. Enable audio and test denied microphone, explanation, and recovery.
2. For each 15/30/60/120-second window, film a visible running clock with audible claps for at least twice the configured interval. Save and compare trigger time, beginning, duration, and lip/clap sync in playback and an exported copy. Repeat before the buffer is full.
3. Save repeatedly while capture continues; verify every clip decodes, matches its own trigger cutoff, and survives cache eviction, app termination, and relaunch. Check audio across two-second segment boundaries. Document dropped frames or gaps.
4. Test front/rear selection while stopped, framing, portrait orientation, matching preview/export orientation, voice recording, muted capture, and library share sheet.
5. Run 30 minutes at 120 seconds. Measure cache bytes, file count, memory, CPU, battery, and thermal state with Instruments. Cache must plateau; no unbounded pixel-buffer/sample queue. Verify visible failure on encoder overload and low disk capacity. Disk guard is sampled, so record maximum threshold overshoot.
6. While buffering: lock/unlock, Home/app switch, notification center, Control Center, phone/FaceTime interruption, Siri, and permission dialog. Camera/microphone indicators must stop; buffer must never auto-resume after return. Repeat during save, including device lock.
7. Start/stop rapidly and background during permission grant or startup. Confirm no delayed camera activation. Do not accept a success status if the capture session failed.
8. Save, close app, restart, preview, export to Photos (grant and deny), share, cancel/delete with confirmation. Verify only the selected clip is deleted. Confirm no save loss after buffer cleanup. Test save failure near full storage and interrupted export.
9. Exercise largest accessibility text, VoiceOver, Reduce Motion, small iPhone display, and one-handed controls. Verify status labels, focus order, visible action buttons, and playback dismissal.
10. Inspect app network activity: no video uploads or analytics. Inspect protected files/backup exclusion using development tools. App uninstall must be documented as deleting local clips.

A release requires recorded results and resolution of hardware-specific failures. This is not a substitute for direct parental supervision or a dedicated baby monitor.
