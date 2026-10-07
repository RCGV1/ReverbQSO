# Distribution checks

Regenerate the Xcode project with `xcodegen generate` after changing `project.yml`. Keep the existing bundle identifiers to preserve saved accounts.

## iPhone and Watch

Archive the `ReverbQSO` scheme for a generic iOS device with the Release configuration. The archive must contain the Watch app and Live Activity extension. Export with App Store distribution profiles for all three bundle identifiers and a distribution certificate whose private key is available on the build Mac. An unsigned archive is useful for compilation checks but is not an installable or uploadable release.

Verify that each embedded product contains its own `PrivacyInfo.xcprivacy`, that versions agree, and that distribution entitlements have `get-task-allow` disabled. Check App Store Connect agreements and create the app record before uploading. Exporting an archive does not submit it for review.

## Mac

Archive the `ReverbQSO` scheme for Mac Catalyst. Release uses `ReverbQSOMacStore.entitlements`: App Sandbox, microphone input, network client/server, user-selected file access, and the shared menu-bar App Group. Debug retains its development entitlements.

The Catalyst archive embeds the native `ReverbQSOMenuBar` app at `Contents/Library/LoginItems`. Sign both apps with the same team and preserve the team-prefixed App Group. Its state and commands travel through the group container; distributed notifications contain no payload. Settings provides an opt-in login-item control through `SMAppService`; check both registration and macOS approval handling on the signed product. The standalone menu-bar scheme remains available for development.

A local development signature verifies sandbox behavior but does not replace Mac App Store distribution signing or Developer ID signing and notarization for a download outside the store. Verify the actual signature and entitlements with `codesign`, not only the project settings. If a compilation-only unsigned archive is re-signed manually before export, apply the Release entitlements to both apps first: export can otherwise produce a signature without the custom sandbox/App Group entitlements. Inspect the exported package again after re-signing.

## Policy and final verification

Keep `PRIVACY.md` and the public policy link in the app consistent. Update the App Store privacy answers when data handling changes. Review the manifest declarations against the APIs in each target, including shared Watch code.

Run the unit suite and localhost codec/transport tests. Live EchoTest checks are explicitly opt-in and use one account session at a time. Keep credentials in the test process, outside repository files and logs. Do not automate CQ matching with actual operators. Verify Bluetooth receive/transmit transitions on physical hardware before advertising device-specific audio behavior.
