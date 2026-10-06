# ReverbQSO

A native SwiftUI amateur-radio voice client for **iPhone, iPad, Mac and Apple Watch**, using the EchoLink network.

Browse repeaters and links, call another operator, or use **Call CQ** to find someone seeking a conversation. Keep your contacts, audio controls and messages together in a QSO view designed for each device.

## Features

- **Station browser:** separate Nodes and People, search, region and country filters, grouped region sorting, country flags, favorites and reconnectable history.
- **Call CQ:** language, country and station-type preferences; queue cancellation; automatic handoff to the normal QSO interface.
- **Voice and text:** hold-to-talk PTT, receive/transmit meters, microphone gain, audio routing, participant lists and chat. GSM, G.711 and Speex reception. Speex transmission is selected automatically when the peer advertises support, with GSM fallback for other peers.
- **Recordings:** explicitly start and stop a QSO recording, play it back, export a WAV file on iPhone/iPad/Mac, or delete it. Incoming personal calls can also be recorded. Silence between audio turns is omitted; each recording is limited to one hour of audio.
- **Call restrictions:** independently apply callsign, country and station-type rules to incoming and outgoing calls, with an optional callsign allow-list.
- **Network options:** Direct UDP, Relay, Public Proxy, Custom Proxy and Automatic selection. Public Proxy retains verified endpoints for up to 24 hours if its HTTPS list is temporarily unavailable, and tries another endpoint if the first cannot reach the directory.
- **Multiple accounts and QSOs:** store credentials in Keychain, open saved accounts immediately with quiet directory recovery, switch accounts and select which connected QSO owns audio and PTT.
- **Apple integration:** native navigation, Mac menu bar companion, Space-to-talk on Mac, iPhone Live Activities and Action Button PTT, plus a standalone or paired Watch client.
- **Incoming calls:** answer or decline a personal call in Direct mode. Mac also supports network conference hosting.

EchoLink requires a validated amateur-radio callsign. ReverbQSO is an independent client and is not affiliated with or endorsed by Synergenics, LLC. EchoLink is its registered trademark.

## Locations and connectivity

Country browsing follows ITU callsign allocations, matching EchoLink’s country-grouping approach. A callsign country is **not a GPS position**. Station descriptions are shown separately as operator-advertised information; the app does not invent coordinates for nodes.

Direct mode needs UDP **5198/5199** to be reachable. Relay provides outgoing calls and cannot receive incoming calls. A public or custom proxy can help on networks that block direct UDP. Personal incoming calls and conference hosting currently require Direct mode; the iPhone incoming listener operates while the app is in the foreground.

Radio hardware control and full Sysop operation are outside the current scope. Dedicated conference-server registration and proxy-hosted incoming calls are not implemented. CQ wire behavior is covered by offline tests; live matching with another operator has not been verified. Speex transmit/receive behavior is covered by encoded-speech, malformed-packet and localhost transport tests; external station interoperability still needs field testing.

## Build

Requirements: macOS, Xcode with Swift 6 and the iOS/watchOS SDKs, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen). Deployment targets are iOS 17, watchOS 10 and macOS 13 for the menu bar companion.

```sh
brew install xcodegen
xcodegen generate
open ReverbQSO.xcodeproj
```

Choose your signing team in Xcode for installation on a device. For unsigned local builds:

```sh
xcodebuild -project ReverbQSO.xcodeproj -scheme ReverbQSO \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project ReverbQSO.xcodeproj -scheme ReverbQSO \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project ReverbQSO.xcodeproj -scheme ReverbQSOWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project ReverbQSO.xcodeproj -scheme ReverbQSOMenuBar \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

If command-line tools point to the standalone CommandLineTools installation, prefix these commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Tests

Run the `ReverbQSO` scheme’s tests using an installed iPhone simulator:

```sh
xcodebuild -project ReverbQSO.xcodeproj -scheme ReverbQSO \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO test
```

Normal test runs use local fixtures and localhost peers. The EchoTest transport smoke test requires explicit opt-in with `ECHOLINK_RUN_LIVE_TESTS=1` and credentials supplied outside the repository. Never commit credentials, provisioning profiles or captured account traffic.

## Repository layout

```text
ReverbQSO/           Shared app, features, protocol and audio services
Companions/Watch/    Standalone and iPhone companion Watch app
Companions/MenuBar/  Native macOS menu bar app
Extensions/         Live Activity extension
Tests/              Swift tests and native codec harness
ThirdParty/         Vendored GSM and Speex codecs, with original licenses
Documentation/      Contributor and architecture notes
project.yml         XcodeGen source of truth
```

Previously named OpenEchoLink. Product names, Swift modules, project files and source paths now use ReverbQSO. Existing bundle identifiers, Keychain service names and saved-data keys are retained for upgrade compatibility; the legacy URL scheme remains supported.

## License

ReverbQSO is licensed under **GNU GPL version 3 or later**. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Vendored libraries retain their original permissive licenses and copyright notices. The app includes these notices under Settings → Licenses.
