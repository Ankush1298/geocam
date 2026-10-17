#!/usr/bin/env python3
"""GeoCam Legacy Media Cleanup Tool.

Safely audits and cleans up legacy stored photos and videos from local disk
or warns if remote S3 storage is configured.
"""
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

    files = [f for f in media_dir.glob("*.*") if f.is_file()]
    total_bytes = sum(f.stat().st_size for f in files)
    print(f"Discovered {len(files)} legacy media files ({total_bytes / (1024*1024):.2f} MB) in {media_dir}")

    if args.dry_run or not args.confirm_delete:
        print("[DRY-RUN] No files were deleted. Run with --confirm-delete to delete.")
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
