# QuadPulse Native

Flutter wrapper app for `https://quadpulse.io/home`.

## Setup

Install Flutter 3.24 or newer, then run:

```sh
flutter pub get
dart run flutter_launcher_icons
dart run flutter_native_splash:create
flutter analyze
flutter build apk --debug
flutter build ios --debug --no-codesign
```

The app icon and splash image come from `assets/brand/quadpulse-icon.png`.

## Native wrapper behavior

- `quadpulse.io` and `www.quadpulse.io` are configured for app/deep links.
- HTTPS pages open internally by default so auth/OAuth flows stay smooth.
- Popup-style auth windows open in a temporary internal WebView.
- Social/map/WhatsApp links open externally.
- The app is portrait-only and respects the system status/navigation bars.
- The WebView appends `QuadPulse-WebNative` to the native user agent.
- Android back goes back in WebView history first, then exits on a second press.

For verified Android App Links and iOS Universal Links, `quadpulse.io` must also
serve the matching `assetlinks.json` and `apple-app-site-association` files.
