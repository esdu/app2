# Required-reason API declarations

[Issue #1](https://github.com/esdu/app2/issues/1) identified three production `ProcessInfo.processInfo.systemUptime` calls without a corresponding privacy declaration. These calls measure elapsed time for the capture watchdog and storage-check intervals; the app does not transmit uptime or derived timing information.

The bundled `PrivacyInfo.xcprivacy` declares:

| Category | Approved reason | App use |
| --- | --- | --- |
| File Timestamp | `C617.1` | Metadata for the app's own buffer files and saved clips |
| Disk Space | `E174.1` | Stop buffering when there is insufficient space for local files |
| System Boot Time | `35F9.1` | Elapsed-time calculations for the watchdog and storage checks |

Apple documents `systemUptime` and reason `35F9.1` in its [required-reason API category reference](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype). Apple's [required-reason API submission guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) remains the authority for distribution requirements.

## Automated packaging checks

`scripts/validate_privacy_manifest.py` scans the app's Swift sources for explicit `systemUptime` access and requires its reviewed System Boot Time reason. With a packaged manifest path, it also compares the parsed property list with the reviewed source manifest, so a missing or stale bundled resource fails CI. It is a narrow regression check for this issue, not a comprehensive required-reason API scanner or a claim of App Store acceptance.

Run the source check on any machine with Python 3:

```sh
python3 scripts/validate_privacy_manifest.py
```

On a Mac with Xcode and the iOS SDK, create an unsigned Release archive and inspect the actual archived resource:

```sh
xcodebuild archive -project LittleMoments.xcodeproj -scheme LittleMoments \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/LittleMoments.xcarchive CODE_SIGNING_ALLOWED=NO
python3 scripts/validate_privacy_manifest.py \
  build/LittleMoments.xcarchive/Products/Applications/LittleMoments.app/PrivacyInfo.xcprivacy
```

GitHub Actions checks the source manifest, the compiled simulator app, and this generic-device archive. The `ios-results-*` artifact includes `Archived-PrivacyInfo.xcprivacy`, `privacy-source.log`, `privacy-simulator.log`, `privacy-archive.log`, `archive.log`, and the archive result bundle alongside the simulator test results. No certificates or provisioning profiles are required for these checks.

## Before distribution

Generate a privacy report and validate the final **signed** distribution archive in Xcode Organizer using the intended Apple Developer team. Confirm the archived app includes all three declarations above and review any additional API usage introduced by future changes or dependencies. A successful unsigned archive and simulator CI do not perform App Store Connect's distribution validation. No signed validation or App Store submission has been performed in this workspace.
