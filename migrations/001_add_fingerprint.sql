-- GeoCam Privacy-First Migration: 001_add_fingerprint.sql
-- Idempotent schema migration to add v3 metadata and region fingerprint columns.

-- 1. SQLite Migration:
-- Run against local SQLite database (data/records.sqlite3)
ALTER TABLE records ADD COLUMN image_dimensions TEXT;
ALTER TABLE records ADD COLUMN fp_version INTEGER DEFAULT 0;
ALTER TABLE records ADD COLUMN fp_sha256 TEXT;
ALTER TABLE records ADD COLUMN region_fingerprints TEXT;

-- 2. PostgreSQL Migration (for RemoteStore):
-- ALTER TABLE records ADD COLUMN IF NOT EXISTS image_dimensions VARCHAR(32);
-- ALTER TABLE records ADD COLUMN IF NOT EXISTS fp_version INTEGER DEFAULT 0;
-- ALTER TABLE records ADD COLUMN IF NOT EXISTS fp_sha256 VARCHAR(64);
-- ALTER TABLE records ADD COLUMN IF NOT EXISTS region_fingerprints TEXT;
