"""Storage backends for the GeoCam verification server.

LocalStore  - SQLite + files on local disk. Fine for local dev, but on Render's
              free plan the disk is wiped on every spin-down/redeploy.
RemoteStore - Postgres (records) + S3-compatible bucket (media). Survives
              restarts. Works with Supabase/Neon + Cloudflare R2/Supabase Storage/B2.
"""
import hashlib
import logging
import sqlite3
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

from flask import redirect, send_file

log = logging.getLogger("geocam.storage")

COLUMNS = (
    "id", "protocol_version", "timestamp", "latitude", "longitude", "accuracy",
    "altitude", "address", "media_type", "signature", "media_sha256",
    "public_key", "created_at",
)


def _ext(media_type):
    return "mp4" if media_type == "video" else "jpg"


def _mime(media_type):
    return "video/mp4" if media_type == "video" else "image/jpeg"


def _now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _values(rec):
    return (
        rec["id"], 2, rec["timestamp"], rec.get("latitude"), rec.get("longitude"),
        rec.get("accuracy"), rec.get("altitude"), rec.get("address", ""),
        rec["mediaType"], rec["signature"], rec["mediaSha256"], rec["publicKey"], _now(),
    )


class LocalStore:
    kind = "local"

    def __init__(self, data_dir, db_path):
        self.media_dir = Path(data_dir) / "media"
        self.db_path = Path(db_path)
        self.media_dir.mkdir(parents=True, exist_ok=True)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with closing(self._connect()) as conn:
            conn.execute("""CREATE TABLE IF NOT EXISTS records (
                id TEXT PRIMARY KEY, protocol_version INTEGER NOT NULL, timestamp TEXT NOT NULL,
                latitude REAL, longitude REAL, accuracy REAL, altitude REAL,
                address TEXT NOT NULL, media_type TEXT NOT NULL, signature TEXT NOT NULL,
                media_sha256 TEXT NOT NULL, public_key TEXT NOT NULL, media_path TEXT NOT NULL,
                created_at TEXT NOT NULL)""")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_records_public_key ON records(public_key)")
            conn.commit()

    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _path(self, rec_id, media_type):
        return self.media_dir / f"{rec_id}.{_ext(media_type)}"

    def get_record(self, rec_id):
        with closing(self._connect()) as conn:
            row = conn.execute("SELECT * FROM records WHERE id=?", (rec_id,)).fetchone()
        if not row:
            return None
        d = dict(row)
        d.pop("media_path", None)
        return d

    def put(self, rec, raw):
        path = self._path(rec["id"], rec["mediaType"])
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_bytes(raw)
        tmp.replace(path)
        with closing(self._connect()) as conn:
            cur = conn.execute(
                "INSERT OR IGNORE INTO records (id, protocol_version, timestamp, latitude, longitude, "
                "accuracy, altitude, address, media_type, signature, media_sha256, public_key, "
                "created_at, media_path) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                _values(rec) + (str(path),),
            )
            conn.commit()
            return cur.rowcount == 1

    def media_exists(self, row):
        return self._path(row["id"], row["media_type"]).exists()

    def media_sha256(self, row):
        path = self._path(row["id"], row["media_type"])
        if not path.exists():
            return None
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()

    def serve_media(self, row):
        return send_file(self._path(row["id"], row["media_type"]), conditional=True)


class RemoteStore:
    kind = "remote"

    def __init__(self, database_url, bucket, endpoint_url, access_key, secret_key, region="auto"):
        import boto3
        import psycopg
        from botocore.config import Config
        from psycopg.rows import dict_row

        self._psycopg, self._dict_row = psycopg, dict_row
        self.database_url = database_url
        self.bucket = bucket
        self.s3 = boto3.client(
            "s3", endpoint_url=endpoint_url or None,
            aws_access_key_id=access_key, aws_secret_access_key=secret_key,
            region_name=region,
            config=Config(signature_version="s3v4", s3={"addressing_style": "path"},
                          retries={"max_attempts": 3},
                          # Newer boto3 adds CRC32 checksum trailers that many S3-compatible
                          # services (Supabase, R2, B2) reject. Only send them when required.
                          request_checksum_calculation="when_required",
                          response_checksum_validation="when_required"),
        )
        with self._connect() as conn:
            conn.execute("""CREATE TABLE IF NOT EXISTS records (
                id TEXT PRIMARY KEY, protocol_version INTEGER NOT NULL, timestamp TEXT NOT NULL,
                latitude DOUBLE PRECISION, longitude DOUBLE PRECISION,
                accuracy DOUBLE PRECISION, altitude DOUBLE PRECISION,
                address TEXT NOT NULL, media_type TEXT NOT NULL, signature TEXT NOT NULL,
                media_sha256 TEXT NOT NULL, public_key TEXT NOT NULL, created_at TEXT NOT NULL)""")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_records_public_key ON records(public_key)")

    def _connect(self):
        return self._psycopg.connect(self.database_url, row_factory=self._dict_row, connect_timeout=10)

    @staticmethod
    def _key(row_id, media_type):
        return f"media/{row_id}.{_ext(media_type)}"

    def get_record(self, rec_id):
        with self._connect() as conn:
            return conn.execute(
                f"SELECT {', '.join(COLUMNS)} FROM records WHERE id=%s", (rec_id,)
            ).fetchone()

    def put(self, rec, raw):
        # Media first, so a record never points at media that does not exist.
        from botocore.exceptions import ClientError
        try:
            self.s3.put_object(Bucket=self.bucket, Key=self._key(rec["id"], rec["mediaType"]),
                               Body=raw, ContentType=_mime(rec["mediaType"]))
        except ClientError as e:
            meta = e.response.get("ResponseMetadata", {})
            log.error("S3 upload failed: http=%s error=%s headers=%s", meta.get("HTTPStatusCode"),
                      e.response.get("Error"), meta.get("HTTPHeaders"))
            raise
        with self._connect() as conn:
            cur = conn.execute(
                f"INSERT INTO records ({', '.join(COLUMNS)}) VALUES ({', '.join(['%s'] * len(COLUMNS))}) "
                "ON CONFLICT (id) DO NOTHING",
                _values(rec),
            )
            return cur.rowcount == 1

    def _head(self, row):
        from botocore.exceptions import ClientError
        try:
            self.s3.head_object(Bucket=self.bucket, Key=self._key(row["id"], row["media_type"]))
            return True
        except ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
                return False
            raise

    def media_exists(self, row):
        return self._head(row)

    def media_sha256(self, row):
        from botocore.exceptions import ClientError
        try:
            obj = self.s3.get_object(Bucket=self.bucket, Key=self._key(row["id"], row["media_type"]))
        except ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
                return None
            raise
        h = hashlib.sha256()
        for chunk in obj["Body"].iter_chunks(1 << 20):
            h.update(chunk)
        return h.hexdigest()

    def serve_media(self, row):
        url = self.s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": self.bucket, "Key": self._key(row["id"], row["media_type"]),
                    "ResponseContentType": _mime(row["media_type"])},
            ExpiresIn=900,
        )
        return redirect(url, code=302)
