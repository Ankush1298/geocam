"""Fingerprint-manifest hardening, Dart<->Python golden manifest and registeredAt tests."""
import base64
import copy
import hashlib
import json
import re
import sqlite3
from pathlib import Path

import pytest

from test_privacy_registration import _app, _client, _gen_key, _make_record, _post_register

GOLDEN_PATH = Path(__file__).parent / "fixtures" / "manifest_v2_golden.json"


def _golden():
    """Read-only. A missing fixture fails clearly; tests never create or modify it."""
    if not GOLDEN_PATH.is_file():
        pytest.fail(f"Missing fixture {GOLDEN_PATH} (tests never create it); restore it from git.")
    return GOLDEN_PATH.read_text()


TILE = "0f0f0f0ff0f0f0f07f0"


def _manifest(**over):
    m = {"algorithm": "grid-luma-v2", "fpVersion": 2, "gridCols": 2, "gridRows": 1,
         "imageHeight": 10, "imageWidth": 10, "regions": [TILE, TILE]}
    m.update(over)
    return {k: v for k, v in m.items() if v is not None}


_counter = iter(range(10_000))


def _register(manifest, *, raw=None, fp_version=None, dims="10x10", extra=None, sha=None):
    """Sign a record whose fpSha256 matches the manifest, so only manifest rules can reject it."""
    text = raw if raw is not None else json.dumps(manifest, separators=(",", ":"), sort_keys=True)
    if fp_version is None:
        fp_version = 2 if isinstance(manifest, dict) and manifest.get("algorithm") == "grid-luma-v2" else 1
    rec = _make_record(_gen_key(), record_id=f"GC-MV-{next(_counter):05d}", proto=3,
                       fp_version=fp_version, fp_sha256=sha or hashlib.sha256(text.encode()).hexdigest(),
                       image_dimensions=dims, region_fingerprints=text)
    if extra:
        rec.update(extra)
    return _post_register(rec), rec


# --------------------------------------------------------------------------- acceptance

def test_dart_generated_golden_manifest_is_accepted_end_to_end():
    GOLDEN = _golden()
    m = json.loads(GOLDEN)
    assert m["algorithm"] == "grid-luma-v2" and m["gpsClockOffsetMs"] == 4200
    resp, rec = _register(None, raw=GOLDEN, fp_version=2, dims=f"{m['imageWidth']}x{m['imageHeight']}")
    assert resp.status_code == 200, resp.get_data(as_text=True)
    api = _client().get(f"/api/record/{rec['id']}").get_json()
    assert api["signatureValid"] is True
    assert api["regionFingerprints"] == GOLDEN  # stored byte-for-byte, so the app's hash check holds
    assert hashlib.sha256(api["regionFingerprints"].encode()).hexdigest() == api["fpSha256"]
    assert api["gpsClockOffsetMs"] == 4200
    page = _client().get(f"/{rec['id']}").get_data(as_text=True)
    assert "within 2 minutes of GPS time (4 s apart)" in page
    assert "does not prove when the photo was taken" in page


def test_valid_v2_max_grid_and_v1_variants_are_accepted():
    big = _manifest(gridRows=16, gridCols=16, regions=[TILE] * 256)     # largest supported luma grid
    assert _register(big)[0].status_code == 200
    first_rejected = _manifest(gridRows=17, gridCols=17, regions=[TILE] * 289)
    assert _register(first_rejected)[0].status_code == 400
    assert _register(_manifest(gridRows=16, gridCols=17, regions=[TILE] * 272))[0].status_code == 400
    v1_big = {"algorithm": "grid-sha256-v1", "fpVersion": 1, "gridCols": 32, "gridRows": 32,
              "imageHeight": 64, "imageWidth": 64, "regions": ["a" * 64] * 1024}
    assert _register(v1_big, dims="64x64")[0].status_code == 200         # v1 keeps larger grids
    v1_over = dict(v1_big, gridRows=65, gridCols=1, regions=["a" * 64] * 65)
    assert _register(v1_over, dims="64x64")[0].status_code == 400        # but never beyond 64
    v1 = {"algorithm": "grid-sha256-v1", "fpVersion": 1, "gridCols": 2, "gridRows": 2,
          "imageHeight": 8, "imageWidth": 8, "regions": ["a" * 64] * 4}
    assert _register(v1, dims="8x8")[0].status_code == 200
    legacy = {"gridCols": 1, "gridRows": 1, "regions": ["b" * 64]}  # no algorithm key: v1 by definition
    assert _register(legacy, fp_version=1)[0].status_code == 200


def test_existing_v2_style_record_without_fingerprints_still_verifies():
    rec = _make_record(_gen_key(), record_id="GC-MV-OLD1")
    assert _post_register(rec).status_code == 200
    assert _client().get("/api/record/GC-MV-OLD1").get_json()["signatureValid"] is True
    page = _client().get("/GC-MV-OLD1").get_data(as_text=True)
    assert "No GPS time reference was recorded" in page


# --------------------------------------------------------------------------- rejection table

BAD = {
    "unknown algorithm": lambda: _manifest(algorithm="grid-luma-v9"),
    "algorithm not a string": lambda: _manifest(algorithm=["grid-luma-v2"]),
    "missing gridRows": lambda: _manifest(gridRows=None),
    "missing regions": lambda: _manifest(regions=None),
    "gridRows bool": lambda: _manifest(gridRows=True, gridCols=2, regions=[TILE] * 2),
    "gridCols float": lambda: _manifest(gridCols=2.0),
    "negative grid": lambda: _manifest(gridRows=-1),
    "zero grid": lambda: _manifest(gridRows=0, regions=[]),
    "luma grid just over the limit": lambda: _manifest(gridRows=17, gridCols=1, regions=[TILE] * 17),
    "grid too big": lambda: _manifest(gridRows=65, gridCols=1, regions=[TILE] * 65),
    "too few tiles": lambda: _manifest(regions=[TILE]),
    "too many tiles": lambda: _manifest(regions=[TILE] * 3),
    "regions is a dict": lambda: _manifest(regions={"a": TILE}),
    "uppercase tile": lambda: _manifest(regions=[TILE.upper(), TILE]),
    "short tile": lambda: _manifest(regions=[TILE[:-1], TILE]),
    "long tile": lambda: _manifest(regions=[TILE + "0", TILE]),
    "bad flat flag": lambda: _manifest(regions=[TILE[:-1] + "2", TILE]),
    "non-hex tile": lambda: _manifest(regions=["g" * 19, TILE]),
    "tile not a string": lambda: _manifest(regions=[123, TILE]),
    "sha tile in luma manifest": lambda: _manifest(regions=["a" * 64, TILE]),
    "luma tile in v1 manifest": lambda: {"algorithm": "grid-sha256-v1", "gridRows": 1, "gridCols": 1, "regions": [TILE]},
    "width missing": lambda: _manifest(imageWidth=None),
    "width bool": lambda: _manifest(imageWidth=True),
    "width float": lambda: _manifest(imageWidth=10.5),
    "width negative": lambda: _manifest(imageWidth=-10),
    "width zero": lambda: _manifest(imageWidth=0),
    "width huge": lambda: _manifest(imageWidth=10**9),
    "fpVersion wrong for algorithm": lambda: _manifest(fpVersion=1),
    "fpVersion bool": lambda: _manifest(fpVersion=True),
    "fpVersion string": lambda: _manifest(fpVersion="2"),
    "gps offset float": lambda: _manifest(gpsClockOffsetMs=1.5),
    "gps offset bool": lambda: _manifest(gpsClockOffsetMs=True),
    "gps offset string": lambda: _manifest(gpsClockOffsetMs="5"),
    "gps offset huge": lambda: _manifest(gpsClockOffsetMs=10**15),
}


@pytest.mark.parametrize("name", sorted(BAD))
def test_malformed_manifest_rejected_with_400_not_500(name):
    resp, rec = _register(BAD[name]())
    assert resp.status_code == 400, (name, resp.status_code, resp.get_data(as_text=True))
    assert "Traceback" not in resp.get_data(as_text=True)
    assert _app.store.get_record(rec["id"]) is None


@pytest.mark.parametrize("raw", ["[]", "null", "42", '"text"', "not json", "{", "{\"regions\": NaN}", "[1,2,3]"])
def test_non_object_or_unparseable_manifest_rejected(raw):
    resp, _ = _register(None, raw=raw, fp_version=1)
    assert resp.status_code == 400


def test_explicit_empty_manifest_string_rejected():
    rec = _make_record(_gen_key(), record_id="GC-MV-EMPTY", proto=3, fp_version=2,
                       fp_sha256=hashlib.sha256(b"").hexdigest(), image_dimensions="10x10")
    rec["regionFingerprints"] = ""
    assert _post_register(rec).status_code == 400


def test_nan_and_infinity_values_rejected():
    for bad in ('{"algorithm":"grid-luma-v2","gridRows":1,"gridCols":1,"imageWidth":10,"imageHeight":10,'
                '"regions":["%s"],"gpsClockOffsetMs":NaN}' % TILE,
                '{"algorithm":"grid-luma-v2","gridRows":1,"gridCols":1,"imageWidth":Infinity,"imageHeight":10,'
                '"regions":["%s"]}' % TILE):
        assert _register(None, raw=bad, fp_version=2)[0].status_code == 400


def test_dimension_and_version_mismatches_with_signed_record_fields_are_rejected():
    assert _register(_manifest(), dims="11x10")[0].status_code == 400   # record dims vs manifest dims
    assert _register(_manifest(), fp_version=1)[0].status_code == 400   # record fpVersion vs algorithm


def test_gps_offset_boundaries():
    ok = 366 * 24 * 3600 * 1000
    assert _register(_manifest(gpsClockOffsetMs=ok))[0].status_code == 200
    assert _register(_manifest(gpsClockOffsetMs=-ok))[0].status_code == 200
    assert _register(_manifest(gpsClockOffsetMs=ok + 1))[0].status_code == 400
    assert _register(_manifest(gpsClockOffsetMs=0))[0].status_code == 200


def test_oversized_inputs_are_bounded():
    huge_tiles = _manifest(gridRows=16, gridCols=16, regions=[TILE] * 256)
    text = json.dumps(huge_tiles) + " " * (300 * 1024)
    assert _register(None, raw=text, fp_version=2)[0].status_code == 400   # > 256 KB manifest
    rec = _make_record(_gen_key(), record_id="GC-MV-BIG")
    rec["address"] = "x" * (600 * 1024)
    assert _post_register(rec).status_code == 413                          # > 512 KB body


# --------------------------------------------------------------------------- tampering

def test_tampering_with_fingerprint_data_after_signing_is_rejected():
    text = json.dumps(_manifest(), separators=(",", ":"), sort_keys=True)
    sha = hashlib.sha256(text.encode()).hexdigest()
    other_tile = TILE.replace("0f0f", "ffff", 1)
    variants = {
        "changed tile": text.replace(TILE, other_tile, 1),
        "swapped order": json.dumps(_manifest(regions=[TILE, other_tile]), separators=(",", ":"), sort_keys=True),
        "changed algorithm": text.replace("grid-luma-v2", "grid-sha256-v1"),
        "changed dimensions": text.replace('"imageWidth":10', '"imageWidth":11'),
        "added offset": text.replace('"fpVersion":2,', '"fpVersion":2,"gpsClockOffsetMs":5,'),
    }
    for name, tampered in variants.items():
        rec = _make_record(_gen_key(), record_id=f"GC-MV-T{next(_counter):05d}", proto=3, fp_version=2,
                           fp_sha256=sha, image_dimensions="10x10", region_fingerprints=text)
        rec["regionFingerprints"] = tampered           # data changed, signed hash unchanged
        assert _post_register(rec).status_code == 400, name

    # Attacker also fixes up fpSha256 to match their edit: the Ed25519 signature no longer verifies.
    rec = _make_record(_gen_key(), record_id="GC-MV-RESIGN", proto=3, fp_version=2, fp_sha256=sha,
                       image_dimensions="10x10", region_fingerprints=text)
    rec["regionFingerprints"] = variants["changed tile"]
    rec["fpSha256"] = hashlib.sha256(variants["changed tile"].encode()).hexdigest()
    resp = _post_register(rec)
    assert resp.status_code == 400 and "signature" in resp.get_json()["error"].lower()


@pytest.mark.parametrize("sig", ["", "!!!notbase64!!!", base64.b64encode(b"short").decode(), None, 12345])
def test_missing_or_malformed_signature_rejected(sig):
    rec = _make_record(_gen_key(), record_id=f"GC-MV-S{next(_counter):05d}")
    if sig is None:
        del rec["signature"]
    else:
        rec["signature"] = sig
    assert _post_register(rec).status_code == 400


# --------------------------------------------------------------------------- registeredAt

UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")


def test_registered_at_is_server_generated_utc_and_persisted_across_reload():
    rec = _make_record(_gen_key(), record_id="GC-RA-1")
    rec["registeredAt"] = "2000-01-01T00:00:00Z"   # client attempts to dictate it
    rec["created_at"] = "1999-01-01T00:00:00Z"
    assert _post_register(rec).status_code == 200
    first = _client().get("/api/record/GC-RA-1").get_json()["registeredAt"]
    assert UTC_RE.match(first) and not first.startswith(("2000", "1999"))
    # repeated reads do not change it
    for _ in range(3):
        assert _client().get("/api/record/GC-RA-1").get_json()["registeredAt"] == first
        assert first in _client().get("/GC-RA-1").get_data(as_text=True)
    # a brand-new store object on the same database sees the same stored value
    from storage import LocalStore
    reloaded = LocalStore(str(_app.store.db_path.parent), str(_app.store.db_path))
    assert reloaded.get_record("GC-RA-1")["created_at"] == first


def test_duplicate_registration_and_sync_retries_keep_the_original_time_and_one_row():
    rec = _make_record(_gen_key(), record_id="GC-RA-2")
    assert _post_register(rec).get_json().get("registered") is True
    first = _client().get("/api/record/GC-RA-2").get_json()["registeredAt"]
    for _ in range(3):
        again = _post_register(rec)
        assert again.status_code == 200 and again.get_json().get("alreadyExists") is True
    assert _client().get("/api/record/GC-RA-2").get_json()["registeredAt"] == first
    with sqlite3.connect(_app.store.db_path) as c:
        assert c.execute("select count(*) from records where id='GC-RA-2'").fetchone()[0] == 1
    other = _make_record(_gen_key(), record_id="GC-RA-2")        # same id, different key/signature
    assert _post_register(other).status_code == 409
    assert _client().get("/api/record/GC-RA-2").get_json()["registeredAt"] == first


def test_record_without_registration_time_is_handled_gracefully():
    rec = _make_record(_gen_key(), record_id="GC-RA-OLD")
    assert _post_register(rec).status_code == 200
    with sqlite3.connect(_app.store.db_path) as c:
        c.execute("update records set created_at='' where id='GC-RA-OLD'")
    api = _client().get("/api/record/GC-RA-OLD").get_json()
    assert api["registeredAt"] is None and api["signatureValid"] is True
    page = _client().get("/GC-RA-OLD").get_data(as_text=True)
    assert "Not recorded (older record)" in page
    assert "Registered on server (not the capture time)" in page
    assert "Captured (device clock, not independently verified)" in page


def test_public_page_never_ties_registration_time_to_capture_time():
    rec = _make_record(_gen_key(), record_id="GC-RA-3")
    assert _post_register(rec).status_code == 200
    page = _client().get("/GC-RA-3").get_data(as_text=True).lower()
    assert "not the capture time" in page
    assert "photo was taken at" not in page and "taken on" not in page


def test_page_flags_a_large_gps_clock_difference():
    resp, rec = _register(_manifest(gpsClockOffsetMs=3 * 3600 * 1000))
    assert resp.status_code == 200
    page = _client().get(f"/{rec['id']}").get_data(as_text=True)
    assert "differed from GPS time by 10800 s" in page and "may be wrong" in page
    resp, rec = _register(_manifest(gpsClockOffsetMs=-90_000))
    ok_page = _client().get(f"/{rec['id']}").get_data(as_text=True)
    assert "within 2 minutes of GPS time (-90 s apart)" in ok_page
    assert "clock-consistency check only" in ok_page


# --------------------------------------------------------------------------- stored-manifest check

def _tamper_db(rec_id, **cols):
    sets = ", ".join(f"{k}=?" for k in cols)
    with sqlite3.connect(_app.store.db_path) as c:
        c.execute(f"update records set {sets} where id=?", (*cols.values(), rec_id))


def _view(rec_id):
    api = _client().get(f"/api/record/{rec_id}").get_json()
    page = _client().get(f"/{rec_id}").get_data(as_text=True)
    return api, page


def test_gps_clock_shown_only_for_a_verified_stored_manifest():
    resp, rec = _register(_manifest(gpsClockOffsetMs=4200))
    api, page = _view(rec["id"])
    assert api["manifestVerified"] is True and api["gpsClockOffsetMs"] == 4200
    assert "4 s apart" in page and api["signatureValid"] is True


def test_missing_manifest_exposes_no_gps_clock_and_does_not_invalidate_the_record():
    rec = _make_record(_gen_key(), record_id="GC-MV-NOFP")
    assert _post_register(rec).status_code == 200
    api, page = _view("GC-MV-NOFP")
    assert api["manifestVerified"] is None and api["gpsClockOffsetMs"] is None
    assert api["signatureValid"] is True
    assert "No GPS time reference was recorded." in page and "could not be verified" not in page


@pytest.mark.parametrize("replacement", [
    "not json at all",                                    # malformed
    "",                                                   # emptied
    '{"gpsClockOffsetMs":999}',                           # valid JSON, different bytes
    None,                                                 # manifest removed from the row
])
def test_tampered_or_damaged_stored_manifest_suppresses_the_offset(replacement):
    resp, rec = _register(_manifest(gpsClockOffsetMs=4200))
    assert resp.status_code == 200
    _tamper_db(rec["id"], region_fingerprints=replacement)
    api, page = _view(rec["id"])
    assert api["gpsClockOffsetMs"] is None
    assert api["signatureValid"] is True                  # display-only field; signed record unaffected
    assert "4 s apart" not in page and "1 s apart" not in page  # 999 ms would render as "1 s"
    if replacement:
        assert api["manifestVerified"] is False
        assert "GPS clock data could not be verified" in page
    else:
        assert "within 2 minutes" not in page


def test_changing_only_the_offset_inside_the_stored_manifest_is_caught():
    resp, rec = _register(_manifest(gpsClockOffsetMs=4200))
    stored = _app.store.get_record(rec["id"])["region_fingerprints"]
    assert '"gpsClockOffsetMs":4200' in stored
    _tamper_db(rec["id"], region_fingerprints=stored.replace('"gpsClockOffsetMs":4200', '"gpsClockOffsetMs":0'))
    api, page = _view(rec["id"])
    assert api["manifestVerified"] is False and api["gpsClockOffsetMs"] is None
    assert "within 2 minutes" not in page


def test_whitespace_difference_in_stored_manifest_is_not_forgiven():
    """The hash is over the exact stored bytes, never a re-serialisation."""
    resp, rec = _register(_manifest(gpsClockOffsetMs=4200))
    stored = _app.store.get_record(rec["id"])["region_fingerprints"]
    _tamper_db(rec["id"], region_fingerprints=stored.replace(",", ", ", 1))
    assert _view(rec["id"])[0]["manifestVerified"] is False


def test_invalid_signature_never_marks_the_manifest_verified():
    resp, rec = _register(_manifest(gpsClockOffsetMs=4200))
    _tamper_db(rec["id"], media_sha256="0" * 64)           # breaks the signature
    api, _ = _view(rec["id"])
    assert api["signatureValid"] is False and api["manifestVerified"] is False
    assert api["gpsClockOffsetMs"] is None
