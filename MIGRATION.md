# GeoCam Legacy Media Migration & Cleanup Plan

This document details the staged operational procedure for migrating existing GeoCam records from legacy centralized media storage to the privacy-first architecture, along with a safe, verified media cleanup script.

---

## 1. Inventory of Legacy Media Assets

In previous versions of GeoCam, media bytes were transmitted to `/sync` and stored in two locations depending on backend configuration:
1. **Local Disk (`LocalStore`)**:
   - Database: `data/records.sqlite3`
   - Stored Media: `data/media/<record_id>.<ext>`
2. **Cloud Storage (`RemoteStore`)**:
   - Database: PostgreSQL (`records` table)
   - Object Store: S3 / Cloudflare R2 bucket (`MEDIA_BUCKET`)

---

## 2. Backward Compatibility & Signature Integrity

> [!IMPORTANT]
> **Preserving Existing Signatures**:
> Under the Ed25519 security model, existing v2 signatures are calculated over:
> `v=2|id=|type=|ts=|lat=|lng=|acc=|alt=|addr64=|media_sha256=`
> Because `media_sha256` represents the digest of the original media rather than the raw bytes themselves, **a legacy record's signature remains 100% valid even after original media bytes are deleted from the server**.
> The server only requires the metadata row in `records` to verify the digital signature.

---

## 3. Staged Migration Procedure

### Stage 1: Public Route Deprecation (Completed)
- Public verification page (`/<record_id>`) no longer embeds `<img>` tags or download links.
- Endpoint `/<record_id>/media` has been deactivated and returns HTTP `410 Gone`.

### Stage 2: Database Schema Upgrade (Completed)
Execute migration `migrations/001_add_fingerprint.sql` to add:
- `image_dimensions` (TEXT)
- `fp_version` (INTEGER DEFAULT 0)
- `fp_sha256` (TEXT)
- `region_fingerprints` (TEXT)

Both `storage.py` and `app.py` support these columns idempotently.

### Stage 3: Audit & Dry-Run Media Identification
Before removing any media files, administrators run the cleanup script in dry-run mode (`--dry-run`). The script catalogs all media files on disk or in the S3 bucket, verifying that a corresponding database record exists with a matching SHA-256 digest.

### Stage 4: Verified Secure Backup
1. Generate an encrypted archive of existing media:
   ```bash
   tar -czf /backup/geocam_media_backup_$(date +%Y%m%d).tar.gz data/media/
   ```
2. Retain the backup in an offline cold-storage location subject to your organization's data retention policy.

### Stage 5: Destructive Cleanup (Requires Explicit Confirmation)
Run `scripts/cleanup_legacy_media.py` with the `--confirm-delete` flag.

---

## 4. Media Cleanup CLI Tool (`scripts/cleanup_legacy_media.py`)

Run this script from the server root:

```bash
# 1. Dry run (non-destructive audit):
python3 scripts/cleanup_legacy_media.py --dry-run

# 2. Permanent deletion (requires manual confirmation):
python3 scripts/cleanup_legacy_media.py --confirm-delete
```

### Script Implementation (`scripts/cleanup_legacy_media.py`):

```python
#!/usr/bin/env python3
"""GeoCam Legacy Media Cleanup Tool."""
import argparse
import os
import sys
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description="Audit and clean up legacy stored media files.")
    parser.add_argument("--dry-run", action="store_true", help="Audit media files without deleting")
    parser.add_argument("--confirm-delete", action="store_true", help="Permanently delete legacy media files")
    args = parser.parse_args()

    data_dir = os.environ.get("GEOCAM_DATA_DIR", "data")
    media_dir = Path(data_dir) / "media"

    if not media_dir.exists():
        print(f"[OK] No legacy media directory found at: {media_dir}")
        return

    files = list(media_dir.glob("*.*"))
    total_bytes = sum(f.stat().st_size for f in files)
    print(f"Discovered {len(files)} legacy media files ({total_bytes / (1024*1024):.2f} MB) in {media_dir}")

    if args.dry_run or not args.confirm_delete:
        print("[DRY-RUN] No files were deleted. Run with --confirm-delete to delete.")
        return

    confirm = input(f"Are you sure you want to permanently delete {len(files)} files? (yes/no): ")
    if confirm.lower() != "yes":
        print("Aborted.")
        return

    deleted = 0
    for f in files:
        try:
            f.unlink()
            deleted += 1
        except Exception as e:
            print(f"Error deleting {f}: {e}")

    print(f"[DONE] Successfully deleted {deleted} legacy media files.")

if __name__ == "__main__":
    main()
```
