# Tawny for iPhone

Tawny turns two phones into a pet monitor: one stays with your pet, one comes
with you. No account, no cloud, no recordings. This is the iPhone app. It
pairs with [Tawny for Android](https://github.com/Tawny-Pet-Monitor/Tawny-APK),
so a household can mix iPhones and Android phones.

## How it is built

- **Native SwiftUI** for every screen you move through: welcome, choosing
  Monitor or Viewer, the QR scanner (AVFoundation), the pairing code
  (Core Image), your sessions, settings, and the tip jar (StoreKit 2). Standard
  iOS controls throughout, in Tawny's own colours, light and dark.
- **The call itself is the shared web engine**, the same one the Android app
  runs: WebRTC video and talk-back, Nostr and rendezvous signalling, chimes,
  snapshots. It is bundled in the app (`Tawny/Web`, vendored from Tawny
  Android's `public/`) and served from `http://127.0.0.1` by
  `LocalWebServer`, so the camera is allowed and nothing loads from the
  internet. Sharing one engine is what keeps iPhone and Android able to
  pair with each other.
- The shell grants the camera and microphone to the bundled page only,
  keeps the screen awake while live, routes sound to the speaker with echo
  cancellation, and reports the Monitor's battery to Viewers.
- No third-party dependencies.

Limits that come from iOS, not from Tawny: the Monitor iPhone has to stay on
Tawny's screen (iOS stops the camera for apps in the background), and it
needs iOS 18.4 or later.

## Licence

MIT. See [LICENSE](LICENSE).
