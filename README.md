# GeoCam (Flutter prototype)

## Setup
```bash
flutter create --org com.yourname --project-name geocam .
# then overwrite lib/main.dart and pubspec.yaml with the ones here
flutter pub get          # or: flutter pub upgrade --major-versions
```

## Android
1. `android/app/build.gradle(.kts)`: set `minSdk = 24`
2. `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`:
```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>
```

## iOS (`ios/Runner/Info.plist`)
```xml
<key>NSCameraUsageDescription</key><string>Take geotagged photos</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Add your location to photos</string>
<key>NSPhotoLibraryAddUsageDescription</key><string>Save photos to your gallery</string>
```

## Run
`flutter run --release` on a real phone (camera + GPS do not work on most emulators).

## What it saves (album "GeoCam")
1. Original photo, untouched pixels, GPS written into EXIF.
2. Stamped copy: same full-resolution photo + strip below with coordinates, address, time, accuracy and a QR code (JPEG 95%).

## Android v0.5.1 GPS fix
The Android build includes camera, fine-location and coarse-location permissions. GeoCam requests location while the app is in use and does not request background location. If the camera opens but GPS remains unavailable, turn on Android Location, allow GeoCam to use Location while using the app, then tap `Retry GPS` in the camera screen.

## Android GPS fix (v0.5.1)
The Android build includes camera, fine-location and coarse-location permissions. GeoCam requests location while the app is in use and does not request background location. If GPS remains unavailable, turn on Android Location, allow GeoCam to use Location while using the app, then tap `Retry GPS` in the camera screen.


## v0.6.6 camera controls
- Video shutter starts recording immediately on finger-down; no long-press delay.
- Release after a hold stops a short clip; a quick tap starts/stops normal video recording.
- Sliding up/down while holding the shutter zooms with one hand.
- Sliding vertically on the preview zooms in both photo and video modes.
- Video recording uses the native camera audio path.
- Video watermark processing remains in the background.
