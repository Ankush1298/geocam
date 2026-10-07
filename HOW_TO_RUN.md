# GeoCam v0.7 — build, test, and verification server

## Android APK

Install Flutter on the build machine, then from this directory:

```bash
flutter clean
flutter pub get
flutter analyze
flutter build apk --release --dart-define=GEOCAM_VERIFICATION_URL=https://YOUR-SERVER.example.com
```

The APK is produced at:

```text
build/app/outputs/flutter-apk/app-release.apk
```

For friends, copy that APK to their Android phones and install it. Android may require allowing installation from the browser/file manager used to open the APK.

### Test APK without a hosted server

The camera, GPS, local history, signatures and media hashing work locally. QR/cloud verification requires the server URL to be reachable.

## Verification server

The repository root contains `app.py`, `requirements.txt`, and `Procfile` for Render/Gunicorn deployment.

Environment variables:

```text
GEOCAM_DATA_DIR=/persistent/geocam-data
GEOCAM_DB=/persistent/geocam-data/records.sqlite3
MAX_UPLOAD_MB=80
```

If the host provides persistent storage, mount it at `/persistent` (or use any persistent path and set both variables accordingly). Without persistent storage, uploaded records/media can disappear when the service is recreated.

Install/run locally:

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python app.py
```

The server accepts only protocol-v2 records. It never needs a GeoCam private key. The phone signs the final media hash and the server verifies using the phone's public key.

## Protocol v2

The phone:

1. Captures the original photo/video.
2. Creates the final stamped media.
3. Writes GPS EXIF to the final photo when available.
4. Computes SHA-256 over the exact final media bytes uploaded for verification.
5. Signs the canonical capture metadata + media SHA-256 using its device-local Ed25519 private key.
6. Stores the signed record locally.
7. Optionally uploads the signed record and exact media to the server.
8. Embeds a QR containing only the verification URL/record ID, avoiding a circular signature/media hash.

The server:

1. Validates the protocol and cryptographic material.
2. Hashes the received media itself.
3. Rejects the upload if its SHA-256 differs from the signed record.
4. Verifies the Ed25519 signature.
5. Stores the media and metadata together in SQLite/filesystem storage.
6. Re-checks both the media hash and signature whenever the QR verification page is opened.

## Testing checklist

Test these cases with at least two Android phones:

- Photo with strong GPS → QR opens and says `MEDIA + SIGNATURE VERIFIED`.
- Video with strong GPS → QR opens and verifies the MP4.
- Airplane mode/offline → capture still works and remains in History.
- Restore network → restart app; pending/failed records retry automatically.
- Change a stored local media byte → History must show `Tampered / Invalid`.
- Change latitude/address in the local record → signature verification must fail.
- Upload a different file while keeping the same signed SHA-256 → server must reject it.
- Re-submit the same record → server should return success without duplicating it.
- Submit the same ID with different signature/media hash → server must reject it.
- Delete a History record → Gallery copy must remain.
- Capture more than 100 records → old GeoCam private files must be removed with old index entries.
- Disable Cloud verification → local signing/history continue, but no media is uploaded.
- Re-enable Cloud verification → pending records can synchronize on the next app start.
- Scan a QR from another phone → verification is independent of the original phone's local storage once synchronized.

## Important trust note

A normal development build creates a device-specific signing key locally. That proves that the record was signed by that GeoCam installation, but it does not by itself prove that the installation is an officially enrolled GeoCam device.

For a production trust model, add a device enrollment/attestation service or configure a server-side allow-list of trusted public keys before distributing a release build.

## One-command APK build

macOS/Linux:

```bash
GEOCAM_VERIFICATION_URL=https://YOUR-SERVER.example.com ./build_apk.sh
```

Windows:

```bat
set GEOCAM_VERIFICATION_URL=https://YOUR-SERVER.example.com
build_apk.bat
```
