# Development

Edit `project.yml`, then run `xcodegen generate`; do not hand-edit the generated Xcode project. Keep deployment and shared source changes compatible with the Watch target.

## Main boundaries

- `App/AppState` owns accounts and the selected directory. `QSOHub` owns concurrent outgoing connections and audio focus.
- `Networking` contains wire formats, transport clients, callsign allocation and access-policy models.
- `Services/EchoLinkConnectionService` owns one outgoing QSO. `AudioEngine` owns capture, decoding, playback and metering.
- `Services/EchoLinkConferenceHostService` owns personal incoming calls and network conferences. It verifies peers against a fresh directory snapshot before admitting them.
- `Services/CallCQService` owns waiting/cancellation state; authenticated HTTP requests use credentials supplied by the directory service.
- `Services/QSORecordingService` streams PCM to WAV files and finalizes recordings when their contact ends. Recording is opt-in. It captures audible RX and transmitted TX; a conference recording also works when local monitoring is disabled.
- `Features` contains native SwiftUI views and their models. Shared Watch services are selected explicitly in `project.yml`.

## Testing rules

Use mock HTTP responses and localhost UDP peers for protocol/state tests. Do not place actual operators in a CQ queue as an automated test. Live EchoTest checks are opt-in and should run one account session at a time.

Test cancellation, disconnect, malformed input, account isolation and audio-focus changes. For codec changes, verify encoded speech, frame boundaries and decoder resets; keep vendored code and copyright notices intact.

Never log passwords or authenticated request headers. Native CQ authentication is sent only over HTTPS to the configured EchoLink service; cross-host and insecure redirects are refused.

## Compatibility

The project and modules use ReverbQSO. Legacy bundle IDs and persistence keys remain intentionally unchanged, allowing existing installations to retain account and favorite data. A change to these identities requires an explicit migration.

## Contributions

App and original test code use `SPDX-License-Identifier: GPL-3.0-or-later`. Do not replace a third-party library’s license. Keep reviewer instructions, agent prompts, device credentials, personal debug traces and build outputs outside the repository.
