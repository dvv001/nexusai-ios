# NexusAI iOS Shell

A thin native shell (SwiftUI + WKWebView) that wraps the NexusAI web app
(https://dvv001.github.io/hghub1/nexus/) as an installable iOS app.

- Persistent WKWebView data store: localStorage (squads, API key) is kept between launches.
- Blob downloads (config export) are bridged to native and offered through the share sheet.
- The project is generated with XcodeGen (`project.yml`); CI builds an unsigned IPA
  on GitHub Actions (macos-15) and uploads it as the `NexusAI-ipa` artifact.
- Install the unsigned IPA with LiveContainer/SideStore, which re-signs it on device.
