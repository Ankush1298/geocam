"""Adversarial integrity/authenticity tests for the GeoCam verification server.

These prove the core product security property: the Ed25519 signature is
cryptographically bound to the exact media bytes via `media_sha256`, so the
pixels cannot be changed while replaying otherwise-valid signed metadata, and
the metadata cannot be changed while keeping the original signature.

Headline regression (the vulnerability this suite guards):
    modified pixels + original signed metadata  ->  REJECT   (test #3)
"""
import base64
import hashlib
import importlib
import io
import json
import os
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

# Configure isolated storage BEFORE importing app (mirrors test_server_protocol).
_tmp = tempfile.TemporaryDirectory()
os.environ["GEOCAM_DATA_DIR"] = _tmp.name
os.environ["GEOCAM_DB"] = str(Path(_tmp.name) / "records.sqlite3")
os.environ.pop("GEOCAM_TRUSTED_PUBLIC_KEYS", None)

import app  # noqa: E402


def _record(private, payload, **overrides):
    public = private.public_key()
    record = {
        "protocolVersion": 2,
        "id": overrides.pop("id", "GC-SEC-001"),
        "timestamp": "2026-10-03T16:12:10.574280Z",
        "latitude": 25.033919,
        "longitude": 74.634770,
        "accuracy": 50.8,
        "altitude": 383.3,
        "address": "Test, India",
        "mediaType": "photo",
        "mediaSha256": hashlib.sha256(payload).hexdigest(),
        "publicKey": base64.b64encode(public.public_bytes_raw()).decode(),
    }
    record.update(overrides)
    record["signature"] = base64.b64encode(private.sign(app.canonical(record))).decode()
    return record


def _sign_over(private, record):
    record["signature"] = base64.b64encode(private.sign(app.canonical(record))).decode()
    return record


def _post(record, media_bytes, filename="GC-SEC-001.jpg"):
    client = app.app.test_client()
    return client.post(
        "/sync",
        data={"record": json.dumps(record), "media": (io.BytesIO(media_bytes), filename)},
        content_type="multipart/form-data",
    )


# 1. Original pixels + valid signed metadata -> ACCEPT.
def test_1_valid_media_and_metadata_accepted():
    private = Ed25519PrivateKey.generate()
    payload = b"authentic-capture-1"
    resp = _post(_record(private, payload, id="GC-SEC-ACCEPT"), payload, "GC-SEC-ACCEPT.jpg")
    assert resp.status_code == 200
    assert resp.get_json()["success"] is True
    page = app.app.test_client().get("/GC-SEC-ACCEPT")
    assert b"MEDIA + SIGNATURE VERIFIED" in page.data


# 2. Original pixels + modified metadata (after signing) -> REJECT.
def test_2_mutated_metadata_rejected():
    private = Ed25519PrivateKey.generate()
    payload = b"authentic-capture-2"
    record = _record(private, payload)
    record["address"] = "Somewhere Else"  # tamper AFTER signature was produced
    assert app.verify_signature(record) is False
    assert _post(record, payload).status_code == 400


# 3. HEADLINE: modified pixels + original signed metadata -> REJECT.
def test_3_tampered_pixels_with_valid_signature_rejected():
    private = Ed25519PrivateKey.generate()
    payload = b"authentic-capture-3"
    record = _record(private, payload)  # signature covers sha256(payload)
    tampered = payload + b"-EVIL"
    assert hashlib.sha256(tampered).hexdigest() != record["mediaSha256"]
    resp = _post(record, tampered)  # replay valid metadata with different pixels
    assert resp.status_code == 400
    assert b"does not match" in resp.data.lower() or b"sha" in resp.data.lower()


# 4a. Modified pixels + mediaSha256 updated to match, but OLD signature kept -> REJECT.
def test_4a_tampered_pixels_rehashed_but_signature_stale_rejected():
    private = Ed25519PrivateKey.generate()
    payload = b"authentic-capture-4a"
    record = _record(private, payload)
    tampered = b"totally-different-bytes"
    record["mediaSha256"] = hashlib.sha256(tampered).hexdigest()  # matches new pixels
    # signature still covers the OLD hash -> signature no longer valid.
    assert app.verify_signature(record) is False
    assert _post(record, tampered).status_code == 400


# 4b. Modified pixels + re-signed with an UNTRUSTED key, enrollment enforced -> REJECT.
def test_4b_attacker_key_rejected_when_enrollment_enforced():
    legit = Ed25519PrivateKey.generate()
    attacker = Ed25519PrivateKey.generate()
    payload = b"forged-capture-4b"
    # Attacker crafts a fully self-consistent record with their OWN key.
    record = _record(attacker, payload, id="GC-SEC-FORGE")
    assert app.verify_signature(record) is True  # internally consistent...

    enrolled = base64.b64encode(legit.public_key().public_bytes_raw()).decode()
    app.TRUSTED_PUBLIC_KEYS = {enrolled}  # only the legit device is enrolled
    try:
        resp = _post(record, payload, "GC-SEC-FORGE.jpg")
        assert resp.status_code == 400
        assert b"not enrolled" in resp.data.lower()
    finally:
        app.TRUSTED_PUBLIC_KEYS = set()


# 5/6. verify_signature covers both pixels (via hash) and every metadata field.
def test_5_6_signature_covers_pixels_and_each_field():
    private = Ed25519PrivateKey.generate()
    record = _record(private, b"cover-all-fields")
    assert app.verify_signature(record) is True
    for field, mutated in [
        ("mediaSha256", "0" * 64),
        ("latitude", 0.0),
        ("longitude", 0.0),
        ("accuracy", 1.0),
        ("altitude", 1.0),
        ("address", "x"),
        ("timestamp", "2020-01-01T00:00:00.000000Z"),
        ("mediaType", "video"),
        ("id", "GC-OTHER"),
    ]:
        clone = dict(record)
        clone[field] = mutated
        assert app.verify_signature(clone) is False, f"{field} not covered by signature"


# 8. Reload/TOCTOU: media swapped at rest after a valid sync -> verify page fails closed.
def test_8_at_rest_media_swap_fails_closed():
    private = Ed25519PrivateKey.generate()
    payload = b"stored-then-swapped"
    assert _post(_record(private, payload, id="GC-SEC-SWAP"), payload, "GC-SEC-SWAP.jpg").status_code == 200
    stored = Path(app.MEDIA_DIR) / "GC-SEC-SWAP.jpg"
    stored.write_bytes(b"swapped-on-disk")  # attacker with FS access alters pixels
    page = app.app.test_client().get("/GC-SEC-SWAP")
    assert b"VERIFICATION FAILED" in page.data or b"failed cryptographic" in page.data
    assert b"MEDIA + SIGNATURE VERIFIED" not in page.data


# 10. Container/serialization tampering cannot bypass verification.
def test_10_record_id_collision_with_different_content_rejected():
    private = Ed25519PrivateKey.generate()
    p1, p2 = b"collision-original", b"collision-replacement"
    assert _post(_record(private, p1, id="GC-SEC-DUP"), p1, "GC-SEC-DUP.jpg").status_code == 200
    # Second, cryptographically-valid-but-different record reusing the same id.
    resp = _post(_record(private, p2, id="GC-SEC-DUP"), p2, "GC-SEC-DUP.jpg")
    assert resp.status_code == 409


# 11. Malformed / unverifiable input fails closed.
def test_11_malformed_inputs_fail_closed():
    private = Ed25519PrivateKey.generate()
    payload = b"malformed-tests"
    client = app.app.test_client()
    # missing multipart fields
    assert client.post("/sync", data={}, content_type="multipart/form-data").status_code == 400
    # bad protocol version
    bad = _record(private, payload, id="GC-SEC-BAD1")
    bad["protocolVersion"] = 1
    _sign_over(private, bad)
    assert _post(bad, payload, "GC-SEC-BAD1.jpg").status_code == 400
    # non-hex media hash
    bad2 = _record(private, payload, id="GC-SEC-BAD2")
    bad2["mediaSha256"] = "nothex"
    _sign_over(private, bad2)
    assert _post(bad2, payload, "GC-SEC-BAD2.jpg").status_code == 400
    # garbage base64 signature
    bad3 = _record(private, payload, id="GC-SEC-BAD3")
    bad3["signature"] = "!!!notbase64!!!"
    assert _post(bad3, payload, "GC-SEC-BAD3.jpg").status_code == 400
    # unknown record on verify endpoint
    assert b"not found" in client.get("/does-not-exist").data.lower()
