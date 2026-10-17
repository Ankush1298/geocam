"""GeoCam Verification Server — Privacy-First Edition (v3).

New in v3:
  POST /register    — Accepts signed metadata only; no media bytes ever stored for
                      new records. Supports region-fingerprint manifests.
  GET  /api/record/<id> — Machine-readable signed record JSON (for app scanner).
  GET  /<id>        — Public verification page; no media preview, no download link.

Legacy (backward-compatible):
  POST /sync        — Kept for existing clients sending media. Stores metadata only;
                      the media bytes are hash-verified but NOT persisted for new
                      registrations made after the privacy upgrade. Existing records
                      with stored media continue to work.
"""
import base64
import hashlib
import json
import os
import time
import re
from datetime import datetime, timezone
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from flask import Flask, abort, jsonify, render_template_string, request

from storage import LocalStore, RemoteStore

app = Flask(__name__)
# Allow reasonably large manifests, but never full media files (80 MB limit is
# a legacy value from when media was accepted; for metadata-only mode 1 MB is
# more than enough — keep the higher cap for the legacy /sync route).
# Legacy /sync (media upload) is OFF unless GEOCAM_ENABLE_LEGACY_SYNC=1; only then is the
# large body cap used. Otherwise every route is capped at 1 MB.
def _legacy_sync_enabled():
    return os.environ.get("GEOCAM_ENABLE_LEGACY_SYNC") == "1"


app.config["MAX_CONTENT_LENGTH"] = (
    int(os.environ.get("MAX_UPLOAD_MB", "80")) if _legacy_sync_enabled() else 1
) * 1024 * 1024

# Maximum size (bytes) for the metadata-only /register body.
_MAX_REGISTER_BYTES = int(os.environ.get("MAX_REGISTER_BYTES", str(512 * 1024)))  # 512 KB

_RATE_LIMIT = int(os.environ.get("GEOCAM_RATE_LIMIT_PER_MIN", "60"))
_rate_hits = {}


@app.before_request
def _rate_limit():
    # ponytail: per-process in-memory window; use a shared store if running several workers.
    if request.path != "/register" and not request.path.startswith("/api/") or _RATE_LIMIT <= 0:
        return None
    now = time.time()
    # Rightmost entry is the one appended by the platform proxy; the leftmost is client-controlled.
    ip = request.headers.get("X-Forwarded-For", request.remote_addr or "").split(",")[-1].strip()
    hits = [t for t in _rate_hits.get(ip, []) if now - t < 60]
    if len(hits) >= _RATE_LIMIT:
        _rate_hits[ip] = hits
        return jsonify(error="Too many requests"), 429
    hits.append(now)
    _rate_hits[ip] = hits
    if len(_rate_hits) > 10000:
        _rate_hits.clear()
    return None


ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$")


def build_store():
    remote_vars = {
        "DATABASE_URL": os.environ.get("DATABASE_URL"),
        "S3_BUCKET": os.environ.get("S3_BUCKET"),
        "S3_ACCESS_KEY_ID": os.environ.get("S3_ACCESS_KEY_ID"),
        "S3_SECRET_ACCESS_KEY": os.environ.get("S3_SECRET_ACCESS_KEY"),
    }
    if any(remote_vars.values()):
        missing = [k for k, v in remote_vars.items() if not v]
        if missing:
            raise RuntimeError("Persistent storage is partly configured; missing: " + ", ".join(missing))
        return RemoteStore(
            remote_vars["DATABASE_URL"], remote_vars["S3_BUCKET"],
            os.environ.get("S3_ENDPOINT_URL"), remote_vars["S3_ACCESS_KEY_ID"],
            remote_vars["S3_SECRET_ACCESS_KEY"], os.environ.get("S3_REGION", "auto"),
        )
    data_dir = os.environ.get("GEOCAM_DATA_DIR", "./data")
    store = LocalStore(data_dir, os.environ.get("GEOCAM_DB", str(Path(data_dir) / "records.sqlite3")))
    if os.environ.get("RENDER"):
        app.logger.warning(
            "Using LOCAL disk on Render: records WILL be lost on restart. "
            "Set DATABASE_URL and S3_* variables."
        )
    return store


store = build_store()

APP_URL = os.environ.get("GEOCAM_APP_URL", "")  # official app listing; button hidden if unset
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
TRUSTED_PUBLIC_KEYS = {x.strip() for x in os.environ.get("GEOCAM_TRUSTED_PUBLIC_KEYS", "").split(",") if x.strip()}

# ---------------------------------------------------------------------------
# Public verification page HTML
# ---------------------------------------------------------------------------
_VERIFY_HTML = """\
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GeoCam Verification</title>
<style>
*{box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f0f2f5;padding:16px;max-width:720px;margin:auto;color:#111}
h1{font-size:1.3rem;margin:0 0 2px}
.subtitle{color:#555;font-size:.85rem;margin-bottom:20px}
.card{background:#fff;padding:22px 20px;border-radius:14px;box-shadow:0 3px 12px rgba(0,0,0,.08);margin-bottom:14px}
.ok{border-left:5px solid #16843b;background:#e8f5e9}
.warn{border-left:5px solid #e65100;background:#fff3e0}
.err{border-left:5px solid #c62828;background:#ffebee}
.status-title{font-size:1rem;font-weight:700;margin:0 0 6px}
.status-body{font-size:.88rem;margin:0;line-height:1.5}
.field{margin:8px 0;font-size:.88rem;word-break:break-word}
.label{font-weight:700;display:inline-block;min-width:130px;color:#333}
.mono{font:11px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:#f5f5f5;padding:8px 10px;border-radius:6px;word-break:break-all;margin:4px 0}
.download-banner{background:linear-gradient(135deg,#1a237e,#283593);color:#fff;border-radius:14px;padding:20px;text-align:center;margin-top:4px}
.download-banner h2{margin:0 0 6px;font-size:1.1rem}
.download-banner p{margin:0 0 14px;font-size:.88rem;opacity:.9;line-height:1.5}
.btn-group{display:flex;gap:10px;justify-content:center;flex-wrap:wrap}
.btn{display:inline-block;padding:10px 18px;border-radius:8px;font-size:.9rem;font-weight:600;text-decoration:none;cursor:pointer}
.btn-primary{background:#fff;color:#1a237e}
.btn-secondary{background:rgba(255,255,255,.15);color:#fff;border:1px solid rgba(255,255,255,.4)}
.privacy-note{font-size:.78rem;color:#888;text-align:center;margin-top:10px}
</style>
</head>
<body>
<h1>🔍 GeoCam Verifier</h1>
<div class="subtitle">Record ID: <strong>{{ record_id }}</strong></div>

{% if error %}
<div class="card err">
  <p class="status-title">❌ Verification Failed</p>
  <p class="status-body">{{ error }}</p>
</div>

{% elif result %}
{# ── Signature status ─────────────────────────────────────── #}
{% if result.sig_ok %}
<div class="card ok">
  <p class="status-title">✅ Signed Record Verified</p>
  <p class="status-body">
    The Ed25519 signature on this record is <strong>cryptographically valid</strong>.
    This confirms the record was signed with the device key shown below and has not been
    altered since. It does not identify who owns that key.<br><br>
    <strong>This does not confirm that the image you received is unmodified.</strong>
    To check for cropping or pixel-level tampering, use the GeoCam app.
  </p>
</div>
{% else %}
<div class="card err">
  <p class="status-title">❌ Invalid Signature</p>
  <p class="status-body">The stored record's Ed25519 signature does not verify. The record may have been altered.</p>
</div>
{% endif %}

{# ── Record fields ────────────────────────────────────────── #}
<div class="card">
  <div class="field"><span class="label">Record ID:</span> {{ result.id }}</div>
  <div class="field"><span class="label">Media type:</span> {{ result.mediaType }}</div>
  <div class="field"><span class="label">Captured:</span> {{ result.timestamp }}</div>
  {% if result.imageDimensions %}<div class="field"><span class="label">Dimensions:</span> {{ result.imageDimensions }}</div>{% endif %}
  <div class="field"><span class="label">Device key:</span> {{ result.keyFingerprint }}</div>
  {% if result.fpVersion is not none and result.fpVersion > 0 %}
  <div class="field"><span class="label">Region check:</span> ✅ Fingerprint data available (use GeoCam app to verify)</div>
  {% else %}
  <div class="field"><span class="label">Region check:</span> Not available for this record</div>
  {% endif %}
  <div class="field">
    <span class="label">SHA-256:</span>
    <div class="mono">{{ result.mediaSha256 }}</div>
  </div>
  <div class="field">
    <span class="label">Signature:</span>
    <div class="mono">{{ result.signature }}</div>
  </div>
</div>

{# ── Important distinction notice ─────────────────────────── #}
<div class="card warn">
  <p class="status-title">⚠️ Record vs. Image Authenticity</p>
  <p class="status-body">
    This page verifies the <em>signed record</em> — it cannot examine the image you received.
    A valid record signature confirms the record has not been tampered with on the server,
    but does <strong>not</strong> confirm the photo you received is unmodified.
    Photos can be cropped or edited before being shared with you while the original QR code
    remains intact.
  </p>
</div>
{% endif %}

{# ── Download banner ──────────────────────────────────────── #}
<div class="download-banner">
  <h2>📱 Check for Photo Tampering</h2>
  <p>
    Download GeoCam to verify the actual photo or video you received.<br>
    The app compares the file on your device against the signed record—no upload required.
  </p>
  <div class="btn-group">
    {% if app_url %}<a class="btn btn-primary" href="{{ app_url }}">Get GeoCam</a>{% endif %}
    <a class="btn btn-secondary" href="/">Learn more</a>
  </div>
</div>

<p class="privacy-note">Original media is not stored on this server. This page shows only signed metadata.</p>
</body>
</html>
"""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def rv(record, camel, snake=None):
    if not isinstance(record, dict):
        return None
    if camel in record:
        return record[camel]
    if snake and snake in record:
        return record[snake]
    return None


def fmt(value, places):
    if value is None:
        return "null"
    return f"{float(value):.{places}f}"


def canonical(record):
    """Canonical signed string — must match HashService._canonical in Flutter.

    v2 (legacy): no image-dimension or fingerprint fields.
    v3 (new):    adds img=<WxH>|fp_version=<int>|fp_sha256=<hex>

    The leading "v=" is the record's protocol version (2 or 3), matching Dart. v2 records
    lack the trailing fields and produce the same bytes they always did.
    """
    proto = record.get("protocolVersion") or record.get("protocol_version") or 2
    address = rv(record, "address") or ""
    address_b64 = base64.b64encode(address.encode("utf-8")).decode("ascii")

    parts = [
        f"v={proto}",
        f"id={record['id']}",
        f"type={rv(record, 'mediaType', 'media_type')}",
        f"ts={record['timestamp']}",
        f"lat={fmt(record.get('latitude'), 6)}",
        f"lng={fmt(record.get('longitude'), 6)}",
        f"acc={fmt(record.get('accuracy'), 1)}",
        f"alt={fmt(record.get('altitude'), 1)}",
        f"addr64={address_b64}",
        f"media_sha256={rv(record, 'mediaSha256', 'media_sha256')}",
    ]

    # v3 extensions — only included when present in the record
    if proto >= 3 or record.get("imageDimensions") or record.get("image_dimensions"):
        img = rv(record, "imageDimensions", "image_dimensions") or ""
        fp_ver = int(record.get("fpVersion") or record.get("fp_version") or 0)
        fp_sha = rv(record, "fpSha256", "fp_sha256") or ""
        parts += [
            f"img={img}",
            f"fp_version={fp_ver}",
            f"fp_sha256={fp_sha}",
        ]

    return "|".join(parts).encode("utf-8")


def validate_record(r, *, require_media_sha256=True):
    """Validate a registration record dict.  Returns the normalised timestamp."""
    required = ["id", "timestamp", "mediaType", "signature", "mediaSha256", "publicKey"]
    missing = [k for k in required if k not in r]
    if missing:
        raise ValueError("Missing fields: " + ", ".join(missing))
    proto = r.get("protocolVersion")
    if proto not in (2, 3):
        raise ValueError("Unsupported protocol version (expected 2 or 3)")
    if not isinstance(r.get("address", ""), str) or len(r.get("address") or "") > 1024:
        raise ValueError("Invalid address")
    if not isinstance(r["id"], str) or not ID_RE.fullmatch(r["id"]):
        raise ValueError("Invalid record id")
    if r["mediaType"] not in ("photo", "video"):
        raise ValueError("Invalid media type")
    if not SHA256_RE.fullmatch(r["mediaSha256"]):
        raise ValueError("Invalid media SHA-256")
    try:
        sig = base64.b64decode(r["signature"], validate=True)
        pub = base64.b64decode(r["publicKey"], validate=True)
        if len(sig) != 64 or len(pub) != 32:
            raise ValueError("Invalid Ed25519 key/signature length")
    except Exception as e:
        raise ValueError("Invalid base64 cryptographic material") from e
    dt = datetime.fromisoformat(r["timestamp"].replace("Z", "+00:00"))
    if dt.tzinfo is None or dt.utcoffset() != timezone.utc.utcoffset(dt):
        raise ValueError("Timestamp must be UTC ISO-8601")
    return r["timestamp"]


def verify_signature(r):
    """Verify Ed25519 signature against the canonical string."""
    try:
        pub_raw = rv(r, "publicKey", "public_key")
        sig_raw = rv(r, "signature", "signature")
        if not pub_raw or not sig_raw:
            return False
        pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(pub_raw, validate=True))
        sig = base64.b64decode(sig_raw, validate=True)
        pub.verify(sig, canonical(r))
        return True
    except (InvalidSignature, ValueError, TypeError, KeyError, IndexError):
        return False


def key_fingerprint(public_key):
    return hashlib.sha256(base64.b64decode(public_key)).hexdigest()[:16]


def row_to_result(row):
    result = dict(row)
    result["keyFingerprint"] = key_fingerprint(result["public_key"])
    result["mediaType"] = result.pop("media_type")
    result["mediaSha256"] = result.pop("media_sha256")
    result["publicKey"] = result.pop("public_key")
    result["sig_ok"] = verify_signature(result)
    # Rename snake_case extras
    result["imageDimensions"] = result.pop("image_dimensions", None)
    result["fpVersion"] = result.pop("fp_version", 0)
    result["fpSha256"] = result.pop("fp_sha256", None)
    result["regionFingerprints"] = result.pop("region_fingerprints", None)
    return result


def _check_manifest_shape(raw):
    """Bound the stored fingerprint manifest so it cannot be used to waste resources."""
    try:
        m = json.loads(raw)
        rows, cols, regions = m["gridRows"], m["gridCols"], m["regions"]
    except (ValueError, KeyError, TypeError):
        raise ValueError("regionFingerprints is not a valid manifest")
    if (not isinstance(rows, int) or not isinstance(cols, int) or not isinstance(regions, list)
            or not 0 < rows <= 64 or not 0 < cols <= 64 or len(regions) != rows * cols
            or not all(isinstance(x, str) and SHA256_RE.fullmatch(x) for x in regions)):
        raise ValueError("regionFingerprints manifest has an invalid grid")


def _check_trusted_key(record):
    if TRUSTED_PUBLIC_KEYS and record["publicKey"] not in TRUSTED_PUBLIC_KEYS:
        raise ValueError("This device public key is not enrolled on the verification server")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/")
def index():
    return (
        "<h2>GeoCam Verification Server is running</h2>"
        "<p>Scan a GeoCam QR code to verify a record.</p>"
    )


@app.post("/register")
def register_record():
    """Privacy-first registration: accepts signed metadata only — no media bytes.

    The client sends JSON (application/json). The body must not exceed
    MAX_REGISTER_BYTES to guard against oversized fingerprint manifests.
    """
    content_length = request.content_length or 0
    if content_length > _MAX_REGISTER_BYTES:
        return jsonify(error="Request body too large for metadata registration"), 413

    try:
        body = request.get_data()
        if len(body) > _MAX_REGISTER_BYTES:
            return jsonify(error="Request body too large for metadata registration"), 413

        record = json.loads(body)
        if not isinstance(record, dict):
            raise ValueError("Request body must be a JSON object")

        timestamp = validate_record(record)
        record["timestamp"] = timestamp

        _check_trusted_key(record)
        if not verify_signature(record):
            return jsonify(error="Ed25519 signature is invalid"), 400

        # Validate optional v3 fields
        if record.get("imageDimensions") is not None:
            dims = record["imageDimensions"]
            if not isinstance(dims, str) or not re.fullmatch(r"\d+x\d+", dims):
                raise ValueError("imageDimensions must be '<width>x<height>'")

        fp_version = int(record.get("fpVersion") or 0)
        fp_sha256 = record.get("fpSha256") or ""
        if fp_version > 0 and fp_sha256 and not SHA256_RE.fullmatch(fp_sha256):
            raise ValueError("fpSha256 must be a 64-character lowercase hex string")

        region_fps = record.get("regionFingerprints")
        if region_fps is not None:
            if not isinstance(region_fps, str):
                raise ValueError("regionFingerprints must be a JSON string")
            if len(region_fps.encode("utf-8")) > 256 * 1024:
                raise ValueError("regionFingerprints manifest is too large (max 256 KB)")
            if hashlib.sha256(region_fps.encode("utf-8")).hexdigest() != fp_sha256:
                raise ValueError("fpSha256 does not match regionFingerprints")
            _check_manifest_shape(region_fps)

        existing = store.get_record(record["id"])
        if existing:
            if (existing["signature"] != record["signature"] or
                    existing["media_sha256"] != record["mediaSha256"]):
                return jsonify(error="Record ID already exists with different cryptographic content"), 409
            return jsonify(success=True, id=record["id"], alreadyExists=True)

        if not store.put_metadata(record):
            # Lost a race with a concurrent insert of the same id: compare, don't assume.
            existing = store.get_record(record["id"])
            if not existing or (existing["signature"] != record["signature"] or
                                existing["media_sha256"] != record["mediaSha256"]):
                return jsonify(error="Record ID already exists with different cryptographic content"), 409
            return jsonify(success=True, id=record["id"], alreadyExists=True)
        return jsonify(success=True, id=record["id"], registered=True)

    except (ValueError, TypeError, json.JSONDecodeError) as e:
        return jsonify(error=str(e)), 400
    except Exception:
        app.logger.exception("register failure")
        return jsonify(error="Server error while storing record"), 500


@app.post("/sync")
def sync_record():
    """Legacy endpoint: accepts media + metadata in multipart form.

    Kept for backward compatibility with older app clients.  For new clients,
    use POST /register instead (metadata-only).

    The media bytes are verified against the signed hash but NOT stored for
    new records created after the privacy upgrade.  Existing records that
    already have media on disk continue to serve it from /media.
    """
    if not _legacy_sync_enabled():
        return jsonify(error="Media upload is disabled. Use POST /register (metadata only)."), 410
    if "media" not in request.files or "record" not in request.form:
        return jsonify(error="Multipart fields 'record' and 'media' are required"), 400
    try:
        record = json.loads(request.form["record"])
        timestamp = validate_record(record)
        record["timestamp"] = timestamp
        media = request.files["media"]
        if not media.filename:
            raise ValueError("Empty media file")
        raw = media.read()
        if not raw:
            raise ValueError("Empty media file")
        if len(raw) > app.config["MAX_CONTENT_LENGTH"]:
            raise ValueError("Media too large")
        actual_hash = hashlib.sha256(raw).hexdigest()
        if actual_hash != record["mediaSha256"]:
            raise ValueError("Media SHA-256 does not match signed record")
        _check_trusted_key(record)
        if not verify_signature(record):
            return jsonify(error="Ed25519 signature is invalid"), 400

        existing = store.get_record(record["id"])
        if existing:
            if (existing["signature"] != record["signature"] or
                    existing["media_sha256"] != record["mediaSha256"]):
                return jsonify(error="Record ID already exists with different cryptographic content"), 409
            return jsonify(success=True, id=record["id"], alreadyExists=True)

        # Store metadata only — do NOT persist the raw media bytes for new records.
        # The hash-verified raw bytes are discarded here intentionally.
        store.put_metadata(record)
        return jsonify(success=True, id=record["id"], verified=True)
    except ValueError as e:
        return jsonify(error=str(e)), 400
    except Exception:
        app.logger.exception("sync failure")
        return jsonify(error="Server error while storing record"), 500


@app.get("/healthz")
def healthz():
    return jsonify(ok=True, storage=store.kind)


@app.get("/api/record/<record_id>")
def api_record(record_id):
    """Machine-readable signed record JSON for the GeoCam in-app scanner.

    Returns signed metadata only — never media bytes.
    Callers must verify the returned signature against the canonical string.
    """
    if not ID_RE.fullmatch(record_id):
        return jsonify(error="Invalid record id"), 400
    row = store.get_record(record_id)
    if not row:
        return jsonify(error="Record not found"), 404
    result = row_to_result(row)
    # Location fields are included because the v2/v3 signature covers them and the
    # app must verify the signature itself rather than trust a server flag. They are
    # NOT shown on the public HTML page. A location-free signature (v4) would remove this.
    safe = {
        "id": result["id"],
        "protocolVersion": row.get("protocol_version", 2),
        "timestamp": result["timestamp"],
        "mediaType": result["mediaType"],
        "latitude": result.get("latitude"),
        "longitude": result.get("longitude"),
        "accuracy": result.get("accuracy"),
        "altitude": result.get("altitude"),
        "address": result.get("address"),
        "mediaSha256": result["mediaSha256"],
        "publicKey": result["publicKey"],
        "signature": result["signature"],
        "imageDimensions": result.get("imageDimensions"),
        "fpVersion": result.get("fpVersion", 0),
        "fpSha256": result.get("fpSha256"),
        "regionFingerprints": result.get("regionFingerprints"),
        "keyFingerprint": result["keyFingerprint"],
        "signatureValid": result["sig_ok"],
    }
    return jsonify(safe)


@app.get("/<record_id>")
def verify_record(record_id):
    """Public QR verification page — shows record metadata, no media preview."""
    row = store.get_record(record_id)
    if not row:
        return render_template_string(
            _VERIFY_HTML,
            record_id=record_id,
            app_url=APP_URL,
            error=(
                "Record not found. No record with this ID exists on the server. "
                "It may never have been synchronised from the phone, "
                "or the server may have lost it."
            ),
        )
    result = row_to_result(row)
    return render_template_string(_VERIFY_HTML, record_id=record_id, result=result, error=None, app_url=APP_URL)


@app.get("/<record_id>/media")
def media(record_id):
    """Legacy media endpoint — disabled for privacy.

    Existing clients that bookmarked this URL will receive a 410 Gone response
    rather than a 404, to clearly signal that media is intentionally unavailable.
    """
    return (
        jsonify(
            error=(
                "Media is not available on this server. "
                "GeoCam stores only signed metadata. "
                "Download the GeoCam app to verify photos locally."
            )
        ),
        410,
    )


@app.errorhandler(413)
def too_large(_):
    return jsonify(error="Upload is too large"), 413


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8765")))
