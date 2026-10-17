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
# optional: GEOCAM_APP_URL, GEOCAM_TRUSTED_PUBLIC_KEYS, GEOCAM_RATE_LIMIT_PER_MIN, GEOCAM_ENABLE_LEGACY_SYNC=1
```

If the host provides persistent storage, mount it at `/persistent` (or use any persistent path and set both variables accordingly). Without persistent storage, registered records can disappear when the service is recreated.

Install/run locally:

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python app.py
```

The server accepts only protocol-v2 records. It never needs a GeoCam private key. The phone signs the final media hash and the server verifies using the phone's public key.

## Protocol v2 / v3 (metadata-only registration)

The phone:

1. Captures the original photo/video and creates the final stamped media.
2. Writes GPS EXIF to the final photo when available.
3. Computes SHA-256 over the exact final media bytes (kept on the phone).
4. For photos, computes the region fingerprint manifest (protocol v3) over the decoded pixels.
5. Signs the canonical string (`v=<protocol>|id=...|media_sha256=...`, plus `img`, `fp_version`, `fp_sha256` for v3) with its device-local Ed25519 key. Videos use v2.
6. Stores the signed record locally.
7. If Cloud verification is on, sends only the signed metadata (JSON) to `POST /register`. Photo/video bytes are never uploaded.
8. Embeds a QR containing only the verification URL/record ID.

The server:

1. Validates the protocol, field sizes and cryptographic material, and bounds the fingerprint manifest.
2. Verifies the Ed25519 signature and that `fpSha256` is the SHA-256 of the manifest.
3. Stores the metadata (SQLite/Postgres). It never has the media.
4. Returns `alreadyExists` for an identical re-send and 409 for the same id with different content.

Sync behaviour in the app: records are marked `pending`, `synced`, `failed` (temporary: offline, timeout, 404/405/429/5xx) or `rejected` (server answered 400/409/413/422, not retried automatically). Unsynced records are retried on app start, when the app returns to the foreground and once a minute while it is open; a scan stops at the first network failure. Turning Cloud verification off stops all uploads and retries.

GPS labels use the device-reported horizontal accuracy in metres: <=10 excellent, <=25 good, <=100 moderate, otherwise weak. "Waiting for GPS" means no fix yet. A cached fix older than 2 minutes is not used. The label says how precise the reading claims to be; it does not prove the location is genuine.

## Testing checklist

Test these cases with at least two Android phones:

- Photo with strong GPS → QR opens and shows the signed record as verified (the page cannot confirm the image itself).
- Video with strong GPS → QR opens and shows the signed record as verified.
- Airplane mode/offline → capture still works and remains in History.
- Restore network → restart app; pending/failed records retry automatically.
- Change a stored local media byte → History must show `Tampered / Invalid`.
- Change latitude/address in the local record → signature verification must fail.
- Register a record whose signature does not match → server must reject it (400).
- Re-submit the same record → server should return success without duplicating it.
- Submit the same ID with different signature/media hash → server must reject it.
- Delete a History record → Gallery copy must remain.
- Capture more than 100 records → old GeoCam private files must be removed with old index entries.
- Disable Cloud verification → local signing/history continue, but no request is made.
- Re-enable Cloud verification → pending records sync within a minute (or on next foreground/start).
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
