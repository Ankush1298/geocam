# GeoCam — Privacy-First Photo Authenticity Verification

GeoCam is an Android camera and verification architecture providing zero-knowledge photo authenticity verification, cryptographic integrity proofs, and advanced on-device tampering/cropping detection.

---

## 🔒 Privacy-First Architecture (v3)

- **Zero Media Storage on Server**: Photos and videos **never leave the user's device**. The verification server receives only cryptographic hashes, metadata, and region fingerprints—zero image/video bytes are transmitted or stored.
- **Dual-Layer Authenticity Verification**:
  - **Layer A (Exact-File Digest)**: SHA-256 over exact authenticated media bytes ensures byte-for-byte fidelity.
  - **Layer B (Region Fingerprint Grid)**: Authenticated 8×8 grid of region SHA-256 digests (`grid-sha256-v1`) enables localized tampering, stamp-removal, and cropping detection without ever transmitting pixels.
- **On-Device Recipient Verification**: Built-in GeoCam QR scanner fetches signed metadata from the server and performs complete Layer A & Layer B analysis **locally on the recipient's phone**.
- **Public Verification Page**: Scanning the QR code with an ordinary smartphone camera opens a clean public page that verifies the digital signature and metadata, clearly prompting users to download GeoCam to inspect their actual received file. Original media is never displayed or downloadable.
- **Local Ed25519 Hardware-Backed Signing**: The private signing key never leaves Android EncryptedSharedPreferences / secure storage.
- **Strict Backward Compatibility**: Fully supports existing v2 historical records.

---

## 🚀 Quick Start & Testing

### Running Flutter Client Tests
```bash
# Run unit and forensics test suites
flutter test test/fingerprint_service_test.dart test/front_camera_test.dart test/exif_probe_test.dart

# Run static analysis
flutter analyze
```

### Running Server Backend Tests
```bash
cd /Volumes/Ankush/geocam_server
python3 -m pytest tests/ -v
```

All 30 backend test cases and 13 Flutter client test cases execute cleanly with 100% pass rate.

---

## 📱 User Workflows

### 1. Sender (Capture & Register)
1. User captures a photo or video with location and timestamp.
2. GeoCam stamps the verified location and QR code into the image.
3. GeoCam computes the exact-file SHA-256 and generates an 8×8 region fingerprint manifest.
4. Device signs the canonical v3 manifest with its private Ed25519 key.
5. Signed metadata is registered to `POST /register` on the server. Original media remains stored strictly on device.

### 2. Recipient (In-App Verification)
1. Recipient opens GeoCam and taps the **Scan / Verify QR** icon in the top bar.
2. Scans the GeoCam QR code on the photo or document.
3. The app fetches the signed record from `/api/record/<id>` and verifies the Ed25519 signature.
4. Recipient selects their received photo from the device file picker.
5. GeoCam performs on-device analysis:
   - **EXACT MATCH**: File SHA-256 matches signed original byte-for-byte.
   - **MODIFICATION DETECTED**: Flags cropping (dimensions changed) or tampering (pinpoints which of the 64 regions were altered).
   - **RECORD AUTHENTIC, IMAGE UNCHECKED**: Record signature is valid before image is picked.

---

## 📚 Technical Documentation

- [`PRIVACY_ARCHITECTURE.md`](file:///Volumes/Ankush/geocam/PRIVACY_ARCHITECTURE.md): Complete cryptographic specification, manifest formats, threat model, and cropping analysis.
- [`MIGRATION.md`](file:///Volumes/Ankush/geocam/MIGRATION.md): Operational guide for migrating legacy media and verified deletion scripts.
- [`migrations/001_add_fingerprint.sql`](file:///Volumes/Ankush/geocam/migrations/001_add_fingerprint.sql): Database schema migration.
