# GeoCam

GeoCam is a location-aware Android camera with local cryptographic integrity records and optional public QR verification.

## What changed in v0.7

- Ed25519 private key moved out of ordinary preferences into Android secure storage.
- Server no longer contains a device private key.
- Photos and videos are both cryptographically signed.
- The signature covers the exact final media SHA-256 digest.
- QR codes identify a record instead of embedding the signature, avoiding a circular hash/signature dependency.
- Server receives the exact media and independently computes its SHA-256.
- Server verifies both media integrity and Ed25519 signature on every public verification.
- Offline captures remain usable locally and retry synchronization later.
- Local history has serialized writes and removes files belonging to records trimmed from the 100-record limit.
- Cloud verification can be disabled in Settings.
- Server storage uses SQLite + media files instead of an in-memory dictionary/JSON-only database.

See `HOW_TO_RUN.md` for Android APK and server deployment instructions.


## Offline-first capture and lightweight Android builds

- Every capture is committed to GeoCam local history before cloud synchronization is required.
- A server outage changes sync state to `failed`/pending; it does not fail the capture.
- Pending records retry while the app is active and again when the app resumes or restarts.
- The app keeps one in-app stamped-media copy instead of duplicating the original, while the independent GeoCam phone Gallery copy remains untouched by deleting GeoCam history.
- The Gallery screen uses a 3-column media grid with photo thumbnails, video first-frame thumbnails, refresh, timestamps, and sync indicators.
- `build_apk.sh` uses `--split-per-abi` so a device-specific APK is much smaller than a universal APK. It also writes debug symbols separately.
