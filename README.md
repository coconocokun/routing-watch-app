# Walking Study for Apple Watch

This project includes a standalone Expo SDK 58 preview and the SwiftUI source for the installed watchOS recorder. The preview displays simulated waiting, recording, pause and transfer states. The native target uses HealthKit and WatchConnectivity on a paired Apple Watch.

## Run the Expo preview

From this directory, use Node 22.13 or later.

```sh
npm ci
npm start
```

For an iPhone simulator development build on macOS, run `npm run ios`. The preview uses synthetic values and does not request HealthKit permissions.

## Install on Apple Watch

The phone app embeds the watchOS 11+ target. Edit the source here in `targets/walk`. Build and sign from [ios_app](../ios_app/README.md) with the same Apple development team on both targets. The phone generates the Watch target on prebuild, so rerun prebuild after adding Watch source files or changing target configuration.

Open the companion on the Watch, start a paired trial from the iPhone, and confirm **Start walk** on the Watch. The Watch requests permission to read heart rate and save the walking workout. It caches live raw samples when available and uses the saved workout’s HealthKit association to verify the final series. Interrupted recovery data is flagged when the final workout source could not be verified.

The Watch persists finalized samples until the phone acknowledges verification. **Retry sync** resends outstanding batches. For protocol 1.0, the checksum covers UTF-8 rows sorted by Watch sequence. Fields are sequence, HealthKit UUID, start and end UTC milliseconds, 16 lowercase hex digits representing the BPM IEEE 754 binary64 bit pattern, source bundle ID, and comma-joined quality flags. Fields use tab separators and rows use LF separators with no final newline. Both apps hash the same representation with SHA-256.

## Verification

```sh
npm run typecheck
npx expo export --platform ios --no-bytecode
```

The Expo checks cover the preview. Native compilation, signing, permissions, workout recovery, and background transfer still need paired-device verification. Record model and OS versions, app versions, workout duration, sample count on both devices, gaps, and disconnection recovery in the device test report.
