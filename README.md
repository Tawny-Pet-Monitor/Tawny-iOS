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

## Building

There is no Mac in this project. GitHub Actions builds everything on its
macOS runners ([`.github/workflows/ios.yml`](.github/workflows/ios.yml)); the
repo is public, so those minutes are free.

Every push to `main` runs two jobs:

| Job | What you get |
|---|---|
| Test and screenshots | Unit tests on the simulator, then every screen in light and dark. Artifact `screenshots`. |
| Device build | An unsigned IPA for sideloading. Artifact `Tawny-unsigned-ipa`. |

The Xcode project is generated from [`project.yml`](project.yml) by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not committed.

When the web app changes in Tawny Android, bring it over with
`tools/sync-web.sh`, then commit `Tawny/Web` and `tools/web-source.txt`.

## Trying it on an iPhone without a developer account

1. Download `Tawny-unsigned-ipa` from the latest run on the Actions tab.
2. Sign and install it with a free Apple Account using a sideloading tool
   such as [iloader](https://github.com/nab138/iloader) (Windows, macOS and
   Linux). Many people use a second Apple Account for this.
3. On the iPhone, turn on Settings → Privacy & Security → Developer Mode.

A free account's signature lasts seven days; sign it again after that.

## TestFlight

Needs the Apple Developer Program.

1. **App ID and app record.** In App Store Connect, Apps → + → New App:
   platform iOS, bundle ID `com.tawny.monitor` (register it under
   Certificates, Identifiers & Profiles first if it isn't offered), any SKU.
2. **API key.** App Store Connect → Users and Access → Integrations → App
   Store Connect API → Team Keys → +, role **Admin** (it lets Xcode create the
   signing certificate itself). Download the `.p8`: Apple offers it once.
3. **Repository secrets** (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `ASC_KEY_ID` | the key's ID |
   | `ASC_ISSUER_ID` | the Issuer ID shown above the keys list |
   | `ASC_PRIVATE_KEY` | the whole text of the `.p8` file |
   | `APPLE_TEAM_ID` | your Team ID (Membership details) |

4. **Run it.** Actions → iOS → Run workflow, tick *testflight*. The build
   appears in TestFlight after Apple processes it (usually 5 to 30 minutes).
   Add yourself as an internal tester; internal testing needs no review.

The build number is the workflow run number, so every upload is new.

## Tips

Tips are consumable in-app purchases (App Review Guideline 3.1.1 allows
tipping the developer). In App Store Connect, under the app → Monetization →
In-App Purchases, create three **Consumable** products:

| Product ID | Suggested price | Reference name |
|---|---|---|
| `com.tawny.monitor.tip.small` | $1.99 | A treat |
| `com.tawny.monitor.tip.medium` | $4.99 | A toy |
| `com.tawny.monitor.tip.large` | $9.99 | A bag of food |

The Paid Apps Agreement has to be active (Business → Agreements) before any
product loads, even in TestFlight. Until then the tip jar says tips aren't
available, which is the intended empty state.

Ko-fi and the Bitcoin (Lightning) tip appear only on the United States
storefront: Guidelines 3.1.1(a) and 3.1.3 allow links to other ways of paying
there and nowhere else. The Bitcoin tip hands off to the person's own wallet;
Tawny never holds keys or funds, so it is not a wallet under Guideline 3.1.5.

## Layout

```
project.yml               XcodeGen spec (targets, Info.plist keys, permissions)
Tawny/App                 entry point, app state, config, diagnostics log
Tawny/Onboarding          welcome, Monitor or Viewer, monitor setup, your name
Tawny/Pairing             pairing-link rules (PairLink), scanner, pairing sheet
Tawny/Home                your sessions
Tawny/Live                live screen, web engine, loopback server
Tawny/Settings            settings, how it works, diagnostics
Tawny/Support             tip jar, Lightning tip
Tawny/Web                 the shared web app (vendored, do not edit here)
TawnyTests                PairLink tests, the same cases as the Android suite
tools/sync-web.sh         vendor the web app from Tawny Android
```

## Licence

MIT. See [LICENSE](LICENSE).
