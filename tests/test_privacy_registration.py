"""Privacy-first registration tests for the GeoCam server.

These tests verify the new /register endpoint (metadata-only), the
/api/record/<id> JSON API, and the public verification page behaviour
under the privacy-first architecture:

1.  /register accepts valid signed metadata (no media bytes) → 200
2.  /register rejects oversized bodies → 413
3.  /register rejects invalid signatures → 400
4.  /register rejects unknown protocol version → 400
5.  /register deduplicates identical records correctly → 200 alreadyExists
6.  /register rejects duplicate ID with different crypto content → 409
7.  /api/record/<id> returns signed metadata JSON after registration
8.  /api/record/<id> does NOT return media bytes or media URL
9.  Public /<id> page has no <img> tag and no media download link
10. Public /<id> page contains the GeoCam download prompt
11. Public /<id> page distinguishes record authenticity from image integrity
12. /media returns 410 Gone (media intentionally disabled)
13. /register accepts v3 manifest with region fingerprint fields
14. Tampered region fingerprint sha256 causes signature mismatch → 400
15. /register body with media field is accepted but media is NOT stored
"""
import base64
import hashlib
import json
import os
import sys
import atexit
import shutil
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

# Configure an isolated storage directory BEFORE importing app so that
# build_store() picks up the right paths regardless of collection order.
# We only set the env var if it hasn't already been configured by another
# test file in the same session (e.g. test_server_protocol.py).
if "GEOCAM_DB" not in os.environ:
    _tmp_priv = tempfile.mkdtemp(prefix="geocam_priv_test_")
    atexit.register(shutil.rmtree, _tmp_priv, ignore_errors=True)
    os.environ["GEOCAM_DATA_DIR"] = _tmp_priv
    os.environ["GEOCAM_DB"] = str(Path(_tmp_priv) / "records_priv.sqlite3")
os.environ.pop("GEOCAM_TRUSTED_PUBLIC_KEYS", None)

# If `app` was already imported (e.g. by another test file), reuse it so we
# share the same in-process SQLite store. If not, import it fresh.
if "app" not in sys.modules:
    import app as _app  # noqa: E402
else:
    import app as _app  # noqa: E402

# Re-expose helpers tests need to call directly.
canonical = _app.canonical
verify_signature = _app.verify_signature
flask_app = _app.app


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _gen_key():
    return Ed25519PrivateKey.generate()


def _make_record(private, *, record_id="GC-PRIV-001", proto=2,
                 fp_version=0, fp_sha256=None,
                 image_dimensions=None, region_fingerprints=None,
                 media_sha256=None):
    payload_bytes = b"fake-local-media-bytes"
    pub = private.public_key()
    rec = {
        "protocolVersion": proto,
        "id": record_id,
        "timestamp": "2026-10-03T16:12:10.574280Z",
        "latitude": 25.033919,
        "longitude": 74.634770,
        "accuracy": 50.8,
        "altitude": 383.3,
        "address": "Test, India",
        "mediaType": "photo",
        "mediaSha256": media_sha256 or hashlib.sha256(payload_bytes).hexdigest(),
        "publicKey": base64.b64encode(pub.public_bytes_raw()).decode(),
    }
    if image_dimensions:
        rec["imageDimensions"] = image_dimensions
    if fp_version:
        rec["fpVersion"] = fp_version
    if fp_sha256:
        rec["fpSha256"] = fp_sha256
    if region_fingerprints:
        rec["regionFingerprints"] = region_fingerprints
    rec["signature"] = base64.b64encode(
        private.sign(canonical(rec))
    ).decode()
    return rec


def _post_register(record):
    client = flask_app.test_client()
    return client.post(
        "/register",
        data=json.dumps(record),
        content_type="application/json",
    )


def _client():
    return flask_app.test_client()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_01_register_valid_metadata_accepted():
    """Valid signed metadata record → 200, no media required."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T01")
    resp = _post_register(rec)
    assert resp.status_code == 200, resp.get_data(as_text=True)
    body = resp.get_json()
    assert body["success"] is True
    assert body["id"] == "GC-PRIV-T01"


def test_02_register_oversized_body_rejected():
    """Bodies exceeding MAX_REGISTER_BYTES are rejected with 413."""
    client = _client()
    # Send a body that is clearly > 512 KB
    resp = client.post(
        "/register",
        data="x" * (600 * 1024),
        content_type="application/json",
        headers={"Content-Length": str(600 * 1024)},
    )
    # Either 413 (caught at route level) or 400 (JSON parse fails) is acceptable.
    assert resp.status_code in (400, 413), resp.status_code


def test_03_register_invalid_signature_rejected():
    """Tampered record after signing → 400."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T03")
    rec["address"] = "Tampered Location"  # invalidate signature
    resp = _post_register(rec)
    assert resp.status_code == 400
    assert b"signature" in resp.data.lower() or b"invalid" in resp.data.lower()


def test_04_register_bad_protocol_version_rejected():
    """Unsupported protocolVersion → 400."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T04", proto=99)
    # Re-sign with wrong version so signature is internally consistent
    rec["signature"] = base64.b64encode(
        private.sign(canonical(rec))
    ).decode()
    resp = _post_register(rec)
    assert resp.status_code == 400


def test_05_register_duplicate_identical_record_ok():
    """Registering the same valid record twice returns alreadyExists=True."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T05")
    r1 = _post_register(rec)
    assert r1.status_code == 200
    r2 = _post_register(rec)
    assert r2.status_code == 200
    assert r2.get_json()["alreadyExists"] is True


def test_06_register_id_collision_different_crypto_rejected():
    """Same record ID with different cryptographic content → 409."""
    private = _gen_key()
    private2 = _gen_key()
    rec1 = _make_record(private, record_id="GC-PRIV-T06")
    rec2 = _make_record(private2, record_id="GC-PRIV-T06")
    r1 = _post_register(rec1)
    assert r1.status_code == 200
    r2 = _post_register(rec2)
    assert r2.status_code == 409


def test_07_api_record_returns_signed_metadata():
    """/api/record/<id> returns JSON with signature, sha256, publicKey."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T07")
    _post_register(rec)

    client = _client()
    resp = client.get("/api/record/GC-PRIV-T07")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["id"] == "GC-PRIV-T07"
    assert body["signature"] == rec["signature"]
    assert body["mediaSha256"] == rec["mediaSha256"]
    assert body["publicKey"] == rec["publicKey"]
    assert body["signatureValid"] is True


def test_08_api_record_no_media_bytes_or_url():
    """/api/record/<id> must not contain any media bytes, URL, or path."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T08")
    _post_register(rec)

    client = _client()
    resp = client.get("/api/record/GC-PRIV-T08")
    assert resp.status_code == 200
    body_text = resp.get_data(as_text=True)
    # No media-related keys
    for forbidden in ("mediaUrl", "media_url", "mediaPath", "media_path", "imageData", "image_data"):
        assert forbidden not in body_text, f"Found forbidden field {forbidden!r} in API response"


def test_09_public_page_no_img_tag_no_media_link():
    """Public verify page must not embed or link to the original photo."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T09")
    _post_register(rec)

    client = _client()
    page = client.get("/GC-PRIV-T09")
    assert page.status_code == 200
    html = page.get_data(as_text=True)
    assert "<img" not in html, "Public page must not embed images"
    assert "/media" not in html, "Public page must not link to media"
    assert "Open original" not in html


def test_10_public_page_has_download_prompt():
    """Public verify page must contain the GeoCam download banner."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T10")
    _post_register(rec)

    client = _client()
    html = client.get("/GC-PRIV-T10").get_data(as_text=True)
    assert "GeoCam" in html
    assert "verify" in html.lower() or "tamper" in html.lower()
    # Should encourage download
    assert "download" in html.lower() or "get geocam" in html.lower()


def test_11_public_page_distinguishes_record_from_image_authenticity():
    """The page must explain that a valid record ≠ unmodified image."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T11")
    _post_register(rec)

    html = _client().get("/GC-PRIV-T11").get_data(as_text=True)
    # Must explain the distinction
    assert "image" in html.lower() or "photo" in html.lower()
    # Must not claim the image is verified without actually checking it
    assert "MEDIA + SIGNATURE VERIFIED" not in html
    # Must mention the record/signature is valid
    assert "verified" in html.lower() or "valid" in html.lower()


def test_12_media_endpoint_returns_410():
    """/<id>/media must return 410 Gone, not a media file."""
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T12")
    _post_register(rec)

    resp = _client().get("/GC-PRIV-T12/media")
    assert resp.status_code == 410, f"Expected 410, got {resp.status_code}"


def test_13_register_v3_with_region_fingerprints():
    """v3 record with region fingerprint fields registers successfully."""
    private = _gen_key()
    # Build a fake fingerprint manifest
    fp_manifest = json.dumps({
        "fpVersion": 1,
        "algorithm": "grid-sha256-v1",
        "imageWidth": 3024,
        "imageHeight": 4032,
        "gridRows": 4,
        "gridCols": 4,
        "regions": [hashlib.sha256(f"region-{i}".encode()).hexdigest() for i in range(16)],
    }, separators=(",", ":"), sort_keys=True)
    fp_sha = hashlib.sha256(fp_manifest.encode("utf-8")).hexdigest()

    rec = _make_record(
        private,
        record_id="GC-PRIV-T13",
        proto=3,
        fp_version=1,
        fp_sha256=fp_sha,
        image_dimensions="3024x4032",
        region_fingerprints=fp_manifest,
    )
    resp = _post_register(rec)
    assert resp.status_code == 200, resp.get_data(as_text=True)

    # Fetch via API and verify fingerprint data round-trips correctly
    api_resp = _client().get("/api/record/GC-PRIV-T13")
    assert api_resp.status_code == 200
    body = api_resp.get_json()
    assert body["fpVersion"] == 1
    assert body["fpSha256"] == fp_sha
    assert body["imageDimensions"] == "3024x4032"
    retrieved_manifest = json.loads(body["regionFingerprints"])
    assert retrieved_manifest["gridRows"] == 4


def test_14_tampered_fp_sha_rejects_signature():
    """If the fp_sha256 is altered after signing, signature verification fails."""
    private = _gen_key()
    fp_manifest = json.dumps({"regions": ["aaa"]}, separators=(",", ":"), sort_keys=True)
    fp_sha = hashlib.sha256(fp_manifest.encode()).hexdigest()

    rec = _make_record(
        private,
        record_id="GC-PRIV-T14",
        proto=3,
        fp_version=1,
        fp_sha256=fp_sha,
        image_dimensions="100x100",
    )
    # Tamper with fp_sha256 after signing
    rec["fpSha256"] = "0" * 64
    resp = _post_register(rec)
    assert resp.status_code == 400


def test_15_legacy_sync_route_still_works():
    """Legacy /sync route with media bytes still registers the record (metadata only)."""
    import io
    private = _gen_key()
    payload = b"legacy-sync-test-payload"
    rec = _make_record(
        private,
        record_id="GC-PRIV-T15",
        media_sha256=hashlib.sha256(payload).hexdigest(),
    )
    client = _client()
    resp = client.post(
        "/sync",
        data={"record": json.dumps(rec), "media": (io.BytesIO(payload), "GC-PRIV-T15.jpg")},
        content_type="multipart/form-data",
    )
    assert resp.status_code == 200, resp.get_data(as_text=True)
    body = resp.get_json()
    assert body["success"] is True

    # Record should be accessible via API
    api = client.get("/api/record/GC-PRIV-T15")
    assert api.status_code == 200
    assert api.get_json()["mediaSha256"] == rec["mediaSha256"]

    # Media must NOT be available (privacy-first: bytes discarded)
    media_resp = client.get("/GC-PRIV-T15/media")
    assert media_resp.status_code == 410


def test_16_legacy_sync_disabled_by_default(monkeypatch):
    monkeypatch.delenv("GEOCAM_ENABLE_LEGACY_SYNC")
    assert _client().post("/sync", data={"record": "{}"}).status_code == 410


def test_17_fp_sha_must_match_manifest():
    private = _gen_key()
    manifest = json.dumps({"fpVersion": 1, "regions": []})
    rec = _make_record(private, record_id="GC-PRIV-T17", proto=3, fp_version=1,
                       fp_sha256="a" * 64, image_dimensions="10x10",
                       region_fingerprints=manifest)
    assert _post_register(rec).status_code == 400


def test_18_api_includes_signed_fields_so_app_can_verify():
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T18")
    assert _post_register(rec).status_code == 200
    body = _client().get("/api/record/GC-PRIV-T18").get_json()
    rebuilt = {k: body[k] for k in ("protocolVersion", "id", "timestamp", "latitude", "longitude",
                                    "accuracy", "altitude", "address", "mediaType", "mediaSha256",
                                    "publicKey", "signature")}
    assert verify_signature(rebuilt)
    page = _client().get("/GC-PRIV-T18").get_data(as_text=True)
    assert "25.033919" not in page  # location never shown on public page


def test_19_untrusted_key_rejected_when_enrollment_enforced(monkeypatch):
    enrolled = _gen_key()
    monkeypatch.setattr(_app, "TRUSTED_PUBLIC_KEYS",
                        {base64.b64encode(enrolled.public_key().public_bytes_raw()).decode()})
    attacker_rec = _make_record(_gen_key(), record_id="GC-PRIV-T19")
    assert _post_register(attacker_rec).status_code == 400


def test_20_rate_limit(monkeypatch):
    monkeypatch.setattr(_app, "_RATE_LIMIT", 3)
    _app._rate_hits.clear()
    codes = [_client().get("/api/record/GC-NOPE-1").status_code for _ in range(5)]
    assert codes[-1] == 429
    _app._rate_hits.clear()


GOLDEN_V3 = ("v=3|id=GC-GOLD-1|type=photo|ts=2026-10-03T16:12:10.574280Z|lat=25.033919|"
             "lng=74.634770|acc=50.8|alt=383.3|addr64=VGVzdCwgSW5kaWE=|media_sha256=" + "ab" * 32 +
             "|img=3024x4032|fp_version=1|fp_sha256=" + "cd" * 32)


def test_21_canonical_matches_dart_golden_vector():
    """Same literal is asserted in test/fingerprint_service_test.dart (HashService)."""
    rec = {"protocolVersion": 3, "id": "GC-GOLD-1", "mediaType": "photo",
           "timestamp": "2026-10-03T16:12:10.574280Z", "latitude": 25.033919,
           "longitude": 74.634770, "accuracy": 50.8, "altitude": 383.3, "address": "Test, India",
           "mediaSha256": "ab" * 32, "imageDimensions": "3024x4032", "fpVersion": 1,
           "fpSha256": "cd" * 32}
    assert canonical(rec).decode() == GOLDEN_V3


def test_22_v3_record_verifies_after_storage():
    private = _gen_key()
    manifest = json.dumps({"algorithm": "grid-sha256-v1", "gridRows": 1, "gridCols": 1,
                           "regions": ["a" * 64]}, sort_keys=True)
    rec = _make_record(private, record_id="GC-PRIV-T22", proto=3, fp_version=1,
                       fp_sha256=hashlib.sha256(manifest.encode()).hexdigest(),
                       image_dimensions="10x10", region_fingerprints=manifest)
    assert _post_register(rec).status_code == 200
    assert _client().get("/api/record/GC-PRIV-T22").get_json()["signatureValid"] is True
    assert "Invalid Signature" not in _client().get("/GC-PRIV-T22").get_data(as_text=True)


def _signed_with_manifest(record_id, manifest):
    try:
        fp_version = 2 if json.loads(manifest).get("algorithm") == "grid-luma-v2" else 1
    except (ValueError, AttributeError):
        fp_version = 1
    rec = _make_record(_gen_key(), record_id=record_id, proto=3, fp_version=fp_version,
                       fp_sha256=hashlib.sha256(manifest.encode()).hexdigest(),
                       image_dimensions="10x10", region_fingerprints=manifest)
    return _post_register(rec)


def test_23_malformed_or_oversized_manifest_rejected():
    big = json.dumps({"gridRows": 1000, "gridCols": 1000, "regions": ["a" * 64] * 10})
    assert _signed_with_manifest("GC-PRIV-T23A", big).status_code == 400
    assert _signed_with_manifest("GC-PRIV-T23B", "not json").status_code == 400
    mismatch = json.dumps({"gridRows": 2, "gridCols": 2, "regions": ["a" * 64]})
    assert _signed_with_manifest("GC-PRIV-T23C", mismatch).status_code == 400
    assert _signed_with_manifest("GC-PRIV-T23D", json.dumps(
        {"gridRows": 1, "gridCols": 1, "regions": ["zz"]})).status_code == 400


def test_24_concurrent_insert_race_is_idempotent_or_409(monkeypatch):
    private = _gen_key()
    rec = _make_record(private, record_id="GC-PRIV-T24")
    assert _post_register(rec).status_code == 200
    monkeypatch.setattr(_app.store, "get_record", lambda _id, _c=[0]: (
        _c.append(1) or (None if len(_c) == 2 else _app.store.__class__.get_record(_app.store, _id))))
    monkeypatch.setattr(_app.store, "put_metadata", lambda r: False)
    resp = _post_register(rec)
    assert resp.status_code == 200 and resp.get_json().get("alreadyExists") is True


def test_25_forged_forwarded_for_cannot_bypass_rate_limit(monkeypatch):
    monkeypatch.setattr(_app, "_RATE_LIMIT", 2)
    _app._rate_hits.clear()
    codes = [_client().get("/api/record/GC-NOPE-2",
                           headers={"X-Forwarded-For": f"1.2.3.{i}, 9.9.9.9"}).status_code
             for i in range(4)]
    assert codes[-1] == 429
    _app._rate_hits.clear()


def test_26_register_works_on_pre_privacy_sqlite_schema(tmp_path):
    import sqlite3
    import storage
    db = tmp_path / "old.sqlite3"
    with sqlite3.connect(db) as c:
        c.execute("""CREATE TABLE records (id TEXT PRIMARY KEY, protocol_version INTEGER NOT NULL,
            timestamp TEXT NOT NULL, latitude REAL, longitude REAL, accuracy REAL, altitude REAL,
            address TEXT NOT NULL, media_type TEXT NOT NULL, signature TEXT NOT NULL,
            media_sha256 TEXT NOT NULL, public_key TEXT NOT NULL, media_path TEXT NOT NULL,
            created_at TEXT NOT NULL)""")
    store = storage.LocalStore(str(tmp_path), str(db))
    rec = _make_record(_gen_key(), record_id="GC-PRIV-T26")
    assert store.put_metadata(rec) is True
    assert store.get_record("GC-PRIV-T26")["media_sha256"] == rec["mediaSha256"]


def test_27_oversized_address_rejected():
    rec = _make_record(_gen_key(), record_id="GC-PRIV-T27")
    rec["address"] = "x" * 2000
    assert _post_register(rec).status_code == 400


def test_28_public_page_makes_no_pixel_or_identity_claims():
    assert _post_register(_make_record(_gen_key(), record_id="GC-PRIV-T28")).status_code == 200
    page = _client().get("/GC-PRIV-T28").get_data(as_text=True)
    assert "does not confirm that the image you received is unmodified" in page
    assert "registered device" not in page
    for banned in ("unmodified</", "not cropped", "pixels match", "authentic photo"):
        assert banned not in page.lower()


def test_29_luma_v2_manifest_accepted_and_bad_tiles_rejected():
    tile = "ffff0000ffff0000" + "7f" + "0"
    ok = json.dumps({"algorithm": "grid-luma-v2", "fpVersion": 2, "gridRows": 1, "gridCols": 2,
                     "imageWidth": 10, "imageHeight": 10, "regions": [tile, tile]})
    assert _signed_with_manifest("GC-PRIV-T29A", ok).status_code == 200
    bad = json.dumps({"algorithm": "grid-luma-v2", "gridRows": 1, "gridCols": 1, "regions": ["a" * 64]})
    assert _signed_with_manifest("GC-PRIV-T29B", bad).status_code == 400
    unknown = json.dumps({"algorithm": "evil-v9", "gridRows": 1, "gridCols": 1, "regions": [tile]})
    assert _signed_with_manifest("GC-PRIV-T29C", unknown).status_code == 400


def test_30_registration_time_is_server_side_and_labelled():
    assert _post_register(_make_record(_gen_key(), record_id="GC-PRIV-T30")).status_code == 200
    api = _client().get("/api/record/GC-PRIV-T30").get_json()
    assert api["registeredAt"] and api["registeredAt"].endswith("Z")
    page = _client().get("/GC-PRIV-T30").get_data(as_text=True)
    assert "Registered on server" in page and "not independently verified" in page


# ---- client IP selection for rate limiting (Render: header configuration is unverified) ----

def _ip(headers=None, header_name="", remote="10.0.0.1"):
    old = _app._CLIENT_IP_HEADER
    _app._CLIENT_IP_HEADER = header_name
    try:
        with flask_app.test_request_context("/api/record/x", headers=headers or {},
                                            environ_base={"REMOTE_ADDR": remote}):
            return _app._client_ip()
    finally:
        _app._CLIENT_IP_HEADER = old


def test_31_client_ip_ignores_all_forwarding_headers_by_default():
    h = {"X-Forwarded-For": "6.6.6.6, 7.7.7.7", "CF-Connecting-IP": "8.8.8.8", "X-Real-IP": "9.9.9.9"}
    assert _ip(h) == "10.0.0.1"
    assert _ip({}) == "10.0.0.1"


def test_32_configured_header_is_used_only_when_it_is_one_valid_ip():
    cf = "CF-Connecting-IP"
    assert _ip({cf: "203.0.113.7"}, cf) == "203.0.113.7"
    assert _ip({cf: " 203.0.113.7 "}, cf) == "203.0.113.7"
    assert _ip({cf: "2001:db8::1"}, cf) == "2001:db8::1"
    for bad in ["", "garbage", "203.0.113.7, 198.51.100.1", "203.0.113.999", "203.0.113.7:8080",
                "1.2.3.4\x00", "' OR 1=1", "a" * 5000]:
        assert _ip({cf: bad}, cf) == "10.0.0.1", bad
    assert _ip({}, cf) == "10.0.0.1"                              # header missing
    assert _ip({"X-Forwarded-For": "5.5.5.5"}, cf) == "10.0.0.1"  # XFF still ignored


def test_33_rate_limit_buckets_follow_the_trusted_header_not_forgeable_ones(monkeypatch):
    monkeypatch.setattr(_app, "_RATE_LIMIT", 2)
    monkeypatch.setattr(_app, "_CLIENT_IP_HEADER", "CF-Connecting-IP")
    _app._rate_hits.clear()
    def hit(ip, xff="1.1.1.1"):
        return _client().get("/api/record/GC-NOPE-3",
                             headers={"CF-Connecting-IP": ip, "X-Forwarded-For": xff}).status_code
    assert [hit("203.0.113.1", f"9.9.9.{i}") for i in range(3)] == [404, 404, 429]  # forged XFF no help
    assert hit("203.0.113.2") == 404                                                 # other client unaffected
    _app._rate_hits.clear()


def _limit_in_fresh_process(**env):
    import subprocess, sys
    code = ("import os,sys,atexit,shutil,tempfile; d=tempfile.mkdtemp(); atexit.register(shutil.rmtree,d,True);"
            "os.environ['GEOCAM_DATA_DIR']=d; os.environ['GEOCAM_DB']=d+'/x.sqlite3';"
            "[os.environ.pop(k,None) for k in ('GEOCAM_ENV','GEOCAM_RATE_LIMIT_PER_MIN')];"
            "os.environ.update(%r); sys.path.insert(0, %r); import app; print(app._RATE_LIMIT)"
            % (env, str(Path(__file__).resolve().parent.parent)))
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60)
    return out.stdout.strip(), out.stderr


def test_34_rate_limit_is_on_by_default_outside_tests():
    assert _limit_in_fresh_process()[0] == "60"
    assert _limit_in_fresh_process(GEOCAM_RATE_LIMIT_PER_MIN="10")[0] == "10"


def test_35_rate_limit_can_only_be_disabled_in_the_test_environment():
    for off in ("0", "-1", "abc", ""):
        assert _limit_in_fresh_process(GEOCAM_RATE_LIMIT_PER_MIN=off)[0] == "60", off
    assert _limit_in_fresh_process(GEOCAM_RATE_LIMIT_PER_MIN="0", GEOCAM_ENV="production")[0] == "60"
    assert _limit_in_fresh_process(GEOCAM_RATE_LIMIT_PER_MIN="0", GEOCAM_ENV="test")[0] == "0"


def test_36_render_yaml_leaves_the_client_ip_header_unset():
    text = (Path(__file__).resolve().parent.parent / "render.yaml").read_text()
    i = text.index("GEOCAM_CLIENT_IP_HEADER")
    block = text[i:].split("- key:")[0]
    assert "sync: false" in block and "value:" not in block
    assert "GEOCAM_RATE_LIMIT_PER_MIN" not in text and "GEOCAM_ENV" not in text
