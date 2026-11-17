# flight_vis (Android pilot app)

Club check-in, flight tracking, and pilot login for [heavenly-tech/flight_vis](https://github.com/heavenly-tech/flight_vis).

## App Links (`flight.heavenly.cl`)

The release app verifies against Digital Asset Links on the server.

| Path | Purpose |
|------|---------|
| `/c/{slug}/q/{token}` | Club QR check-in (multi-club) |
| `/auth/magic/{token}` | Email magic-link login |

`AndroidManifest.xml` uses `android:autoVerify="true"` for `https://flight.heavenly.cl` with `pathPrefix` `/c/` and `/auth/magic/`. There are no custom URI schemes; the web fallback page may launch `intent://…#Intent;scheme=https;package=cl.heavenly.flightvis;…` which the app resolves to the same HTTPS paths.

### Signing certificate SHA-256 for `assetlinks.json`

The server team needs the app’s **release** and (for sideload/testing) **debug** signing cert SHA-256 fingerprints.

### CI release keystore (GitHub Actions)

Production builds (`push` to `main` or `v*` tags) **fail** unless these repository secrets are set:

| Secret | Purpose |
|--------|---------|
| `FLIGHTVIS_KEYSTORE_BASE64` | Base64-encoded release `.jks` / `.keystore` |
| `FLIGHTVIS_KEYSTORE_PASSWORD` | Keystore password |
| `FLIGHTVIS_KEY_ALIAS` | Key alias inside the store |
| `FLIGHTVIS_KEY_PASSWORD` | Private key password |

Use **one stable release keystore forever**. Rotating it breaks Android App Links until `assetlinks.json` is updated with the new certificate SHA-256. Pull-request CI may produce a **debug-signed** APK artifact named `flight-vis-android-debugsigned-<sha>`; do not ship that build. Release runs upload `build/app-release.cert-sha256` (from `apksigner verify --print-certs`) for the server team.

**Release APK / Play App Signing**

If you build with the `FLIGHTVIS_KEYSTORE_*` CI secrets (`android/release.keystore`):

```bash
keytool -list -v -keystore android/release.keystore -alias YOUR_KEY_ALIAS
```

Enter the keystore password when prompted. Copy the **SHA-256** line under `Certificate fingerprints`.

**Gradle signing report (all variants on a dev machine)**

```bash
cd android && ./gradlew signingReport
```

Look for `SHA-256` under `release` and `debug` config blocks.

**Debug keystore (local emulator / unsigned CI APK)**

Default Android debug keystore:

```bash
keytool -list -v \
  -keystore ~/.android/debug.keystore \
  -alias androiddebugkey \
  -storepass android -keypass android
```

Publish fingerprints in `https://flight.heavenly.cl/.well-known/assetlinks.json` for package name `cl.heavenly.flightvis`.

## Development

```bash
flutter pub get
flutter analyze
flutter test
```

Emulator screenshot flow (CI): `integration_test/screenshot_flow_test.dart` and `integration_test/deep_link_checkin_test.dart`.