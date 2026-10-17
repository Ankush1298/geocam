"""Storage backends for the GeoCam verification server.

LocalStore  - SQLite + files on local disk. Fine for local dev, but on Render's
              free plan the disk is wiped on every spin-down/redeploy.
RemoteStore - Postgres (records) + S3-compatible bucket (metadata JSON). Survives
              restarts. Works with Supabase/Neon + Cloudflare R2/Supabase Storage/B2.

Schema v3 adds:
  image_dimensions TEXT   — e.g. "3024x4032"
  fp_version       INTEGER — fingerprint algorithm version (0 = none, 1 = grid-sha256-v1)
  fp_sha256        TEXT   — SHA-256 of the canonical fingerprint manifest
  region_fingerprints TEXT — compact JSON string of per-region hashes

No media bytes are stored for records registered via the privacy-first /register
endpoint.  The legacy /sync route also no longer persists media bytes.
"""
import logging
import sqlite3
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger("geocam.storage")

# All columns returned to the application layer.
COLUMNS = (
    "id", "protocol_version", "timestamp", "latitude", "longitude", "accuracy",
    "altitude", "address", "media_type", "signature", "media_sha256",
    "public_key", "image_dimensions", "fp_version", "fp_sha256",
    "region_fingerprints", "created_at",
)


def _now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _rv(rec, camel, snake=None):
    if not isinstance(rec, dict):
        return None
    if camel in rec:
        return rec[camel]
    if snake and snake in rec:
        return rec[snake]
    return None


def _meta_values(rec):
    """Extract a tuple matching COLUMNS order for INSERT."""
    return (
        rec["id"],
        rec.get("protocolVersion") or 2,
        rec["timestamp"],
        rec.get("latitude"),
        rec.get("longitude"),
        rec.get("accuracy"),
        rec.get("altitude"),
        rec.get("address") or "",
        _rv(rec, "mediaType", "media_type"),
        rec["signature"],
        _rv(rec, "mediaSha256", "media_sha256"),
        _rv(rec, "publicKey", "public_key"),
        _rv(rec, "imageDimensions", "image_dimensions"),
        int(rec.get("fpVersion") or rec.get("fp_version") or 0),
        _rv(rec, "fpSha256", "fp_sha256"),
        rec.get("regionFingerprints") or rec.get("region_fingerprints"),
        _now(),
    )


# ---------------------------------------------------------------------------
# LocalStore
# ---------------------------------------------------------------------------

class LocalStore:
    kind = "local"

    _CREATE_TABLE = """
        CREATE TABLE IF NOT EXISTS records (
            id                  TEXT PRIMARY KEY,
            protocol_version    INTEGER NOT NULL,
            timestamp           TEXT NOT NULL,
            latitude            REAL,
            longitude           REAL,
            accuracy            REAL,
            altitude            REAL,
            address             TEXT NOT NULL DEFAULT '',
            media_type          TEXT NOT NULL,
            signature           TEXT NOT NULL,
            media_sha256        TEXT NOT NULL,
            public_key          TEXT NOT NULL,
            image_dimensions    TEXT,
            fp_version          INTEGER NOT NULL DEFAULT 0,
            fp_sha256           TEXT,
            region_fingerprints TEXT,
            created_at          TEXT NOT NULL
        )
    """

    def __init__(self, data_dir, db_path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self._connect()) as conn:
            conn.execute(self._CREATE_TABLE)
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_records_public_key ON records(public_key)"
            )
            # Idempotent migrations for databases created before v3.
            self._migrate(conn)
            conn.commit()
            # Pre-privacy databases have a NOT NULL media_path column; keep filling it with ''.
            self._legacy_media_path = "media_path" in {
                r[1] for r in conn.execute("PRAGMA table_info(records)").fetchall()
            }

    @staticmethod
    def _migrate(conn):
        """Add v3 columns to pre-existing databases without dropping data."""
        existing = {
            row[1] for row in conn.execute("PRAGMA table_info(records)").fetchall()
        }
        migrations = [
            ("image_dimensions",    "ALTER TABLE records ADD COLUMN image_dimensions TEXT"),
            ("fp_version",          "ALTER TABLE records ADD COLUMN fp_version INTEGER NOT NULL DEFAULT 0"),
            ("fp_sha256",           "ALTER TABLE records ADD COLUMN fp_sha256 TEXT"),
            ("region_fingerprints", "ALTER TABLE records ADD COLUMN region_fingerprints TEXT"),
        ]
        for col, sql in migrations:
            if col not in existing:
                conn.execute(sql)
                log.info("Migrated: added column %s", col)
        # Remove legacy media_path column reference — it may not exist in new dbs.
        # We do NOT drop it if it exists so existing data is safe.

    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def get_record(self, rec_id):
        with closing(self._connect()) as conn:
            row = conn.execute(
                f"SELECT {', '.join(COLUMNS)} FROM records WHERE id=?", (rec_id,)
            ).fetchone()
        return dict(row) if row else None

    def put_metadata(self, rec):
        """Store only signed metadata — no media bytes accepted or stored."""
        cols, values = list(COLUMNS), list(_meta_values(rec))
        if self._legacy_media_path:
            cols.append("media_path")
            values.append("")
        placeholders = ", ".join(["?"] * len(cols))
        with closing(self._connect()) as conn:
            cur = conn.execute(
                f"INSERT OR IGNORE INTO records ({', '.join(cols)}) VALUES ({placeholders})",
                values,
            )
            conn.commit()
            return cur.rowcount == 1

    # ── Legacy methods kept for tests / backward compat ──────────────────────

    def put(self, rec, raw=None):  # noqa: ARG002  raw is intentionally ignored
        """Alias for put_metadata; raw bytes are accepted but discarded."""
        return self.put_metadata(rec)

    def media_exists(self, row):
        """Always False — media is no longer stored."""
        return False

    def media_sha256(self, row):
        """Returns None — media is not stored; hash comes from the signed record."""
        return None

    def serve_media(self, row):
        raise NotImplementedError("Media serving is disabled in the privacy-first server")


# ---------------------------------------------------------------------------
# RemoteStore
# ---------------------------------------------------------------------------

class RemoteStore:
    kind = "remote"

    _CREATE_TABLE = """
        CREATE TABLE IF NOT EXISTS records (
            id                  TEXT PRIMARY KEY,
            protocol_version    INTEGER NOT NULL,
            timestamp           TEXT NOT NULL,
            latitude            DOUBLE PRECISION,
            longitude           DOUBLE PRECISION,
            accuracy            DOUBLE PRECISION,
            altitude            DOUBLE PRECISION,
            address             TEXT NOT NULL DEFAULT '',
            media_type          TEXT NOT NULL,
            signature           TEXT NOT NULL,
            media_sha256        TEXT NOT NULL,
            public_key          TEXT NOT NULL,
            image_dimensions    TEXT,
            fp_version          INTEGER NOT NULL DEFAULT 0,
            fp_sha256           TEXT,
            region_fingerprints TEXT,
            created_at          TEXT NOT NULL
        )
    """

    def __init__(self, database_url, bucket, endpoint_url, access_key, secret_key, region="auto"):
        import psycopg
        from psycopg.rows import dict_row

        self._psycopg, self._dict_row = psycopg, dict_row
        self.database_url = database_url
        # S3 bucket kept in case legacy media still needs to be cleared by ops.
        self.bucket = bucket
        self._endpoint_url = endpoint_url
        self._access_key = access_key
        self._secret_key = secret_key
        self._region = region

        with self._connect() as conn:
            conn.execute(self._CREATE_TABLE)
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_records_public_key ON records(public_key)"
            )
            self._migrate(conn)

    @staticmethod
    def _migrate(conn):
        """Idempotent column additions for pre-v3 databases."""
        migrations = [
            "ALTER TABLE records ADD COLUMN IF NOT EXISTS image_dimensions TEXT",
            "ALTER TABLE records ADD COLUMN IF NOT EXISTS fp_version INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE records ADD COLUMN IF NOT EXISTS fp_sha256 TEXT",
            "ALTER TABLE records ADD COLUMN IF NOT EXISTS region_fingerprints TEXT",
        ]
        for sql in migrations:
            try:
                conn.execute(sql)
                log.info("Remote migration: %s", sql)
            except Exception:
                log.exception("Remote migration failed (continuing): %s", sql)

    def _connect(self):
        return self._psycopg.connect(
            self.database_url, row_factory=self._dict_row, connect_timeout=10
        )

    def get_record(self, rec_id):
        with self._connect() as conn:
            return conn.execute(
                f"SELECT {', '.join(COLUMNS)} FROM records WHERE id=%s", (rec_id,)
            ).fetchone()

    def put_metadata(self, rec):
        """Store signed metadata only."""
        col_list = ", ".join(COLUMNS)
        placeholders = ", ".join(["%s"] * len(COLUMNS))
        with self._connect() as conn:
            cur = conn.execute(
                f"INSERT INTO records ({col_list}) VALUES ({placeholders}) "
                "ON CONFLICT (id) DO NOTHING",
                _meta_values(rec),
            )
            return cur.rowcount == 1

    # ── Legacy ────────────────────────────────────────────────────────────────

    def put(self, rec, raw=None):  # noqa: ARG002
        """Alias for put_metadata; raw bytes are accepted but discarded."""
        return self.put_metadata(rec)

    def media_exists(self, row):
        return False

    def media_sha256(self, row):
        return None

    def serve_media(self, row):
        raise NotImplementedError("Media serving is disabled in the privacy-first server")
