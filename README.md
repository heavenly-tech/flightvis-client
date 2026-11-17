# flight_vis (Android pilot tracker)

Flutter Android client for [heavenly-tech/flight_vis](https://github.com/heavenly-tech/flight_vis) club operations: pilot login, device pairing, kiosk check-in, tail selection, and live tracking via the Traccar Client SDK (`/api/osmand`).

Derived from [traccar/traccar-client](https://github.com/traccar/traccar-client); see [NOTICE](NOTICE).

## Configuration

Default server URL: `https://flight.heavenly.cl`

Override at build time:

```bash
flutter build apk --dart-define=FLIGHTVIS_BASE_URL=https://flight.heavenly.cl
```

Tap the app title seven times on the home hub to change the server URL at runtime.

## Local development

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

## CI secrets (release signing)

Optional GitHub Actions secrets:

- `FLIGHTVIS_KEYSTORE_BASE64`
- `FLIGHTVIS_KEYSTORE_PASSWORD`
- `FLIGHTVIS_KEY_ALIAS`
- `FLIGHTVIS_KEY_PASSWORD`

If absent, CI builds a debug-signed release APK and notes that in the job summary.