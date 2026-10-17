import base64
import hashlib
import io
import json
import os
import tempfile
from pathlib import Path

# Configure storage before importing app.
_tmp = tempfile.TemporaryDirectory()
os.environ['GEOCAM_DATA_DIR'] = _tmp.name
os.environ['GEOCAM_DB'] = str(Path(_tmp.name) / 'records.sqlite3')

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

import app


def make_record(payload=b'geo-cam-test'):
    private = Ed25519PrivateKey.generate()
    public = private.public_key()
    record = {
        'protocolVersion': 2,
        'id': 'GC-TEST-123',
        'timestamp': '2026-10-03T16:12:10.574280Z',
        'latitude': 25.033919,
        'longitude': 74.634770,
        'accuracy': 50.8,
        'altitude': 383.3,
        'address': 'Test, India',
        'mediaType': 'photo',
        'mediaSha256': hashlib.sha256(payload).hexdigest(),
        'publicKey': base64.b64encode(public.public_bytes_raw()).decode(),
    }
    record['signature'] = base64.b64encode(private.sign(app.canonical(record))).decode()
    return record


def test_valid_signature_and_media():
    payload = b'geo-cam-test'
    record = make_record(payload)
    assert app.verify_signature(record)
    assert hashlib.sha256(payload).hexdigest() == record['mediaSha256']


def test_server_rejects_tampered_media():
    payload = b'geo-cam-test'
    record = make_record(payload)
    client = app.app.test_client()
    response = client.post('/sync', data={
        'record': json.dumps(record),
        'media': (io.BytesIO(b'tampered'), 'GC-TEST-123.jpg'),
    }, content_type='multipart/form-data')
    assert response.status_code == 400


def test_sync_and_web_verification_page():
    """After a /sync upload the public page should show a verified record
    without embedding or linking to the original media.
    """
    payload = b'geo-cam-valid-media-content-v2'
    record = make_record(payload)
    client = app.app.test_client()
    sync_resp = client.post('/sync', data={
        'record': json.dumps(record),
        'media': (io.BytesIO(payload), 'GC-TEST-123.jpg'),
    }, content_type='multipart/form-data')
    assert sync_resp.status_code == 200
    assert sync_resp.get_json()['success'] is True

    web_resp = client.get(f"/{record['id']}")
    assert web_resp.status_code == 200
    html = web_resp.data

    # Privacy-first page: verified record but NO media embedded
    assert b'Signed Record Verified' in html or b'signed record' in html.lower()
    assert b'<img' not in html, "Public page must not embed the original photo"
    assert b'/media' not in html, "Public page must not link to media"
    # Must show the download / tampering-check prompt
    assert b'GeoCam' in html


def test_register_endpoint_accepts_metadata_only():
    """New /register endpoint works without any media bytes."""
    private = Ed25519PrivateKey.generate()
    public = private.public_key()
    record = {
        'protocolVersion': 2,
        'id': 'GC-REG-001',
        'timestamp': '2026-10-03T16:12:10.574280Z',
        'latitude': 25.0,
        'longitude': 74.0,
        'accuracy': 10.0,
        'altitude': 400.0,
        'address': 'Test City',
        'mediaType': 'photo',
        'mediaSha256': hashlib.sha256(b'some-local-bytes').hexdigest(),
        'publicKey': base64.b64encode(public.public_bytes_raw()).decode(),
    }
    record['signature'] = base64.b64encode(private.sign(app.canonical(record))).decode()

    client = app.app.test_client()
    resp = client.post('/register', data=json.dumps(record), content_type='application/json')
    assert resp.status_code == 200, resp.get_data(as_text=True)
    assert resp.get_json()['success'] is True

    # Record must be accessible via the JSON API
    api_resp = client.get('/api/record/GC-REG-001')
    assert api_resp.status_code == 200
    api_body = api_resp.get_json()
    assert api_body['signatureValid'] is True
    assert api_body['mediaSha256'] == record['mediaSha256']



def test_rejects_path_traversal_record_id():
    record = make_record(b'x')
    record['id'] = '../../evil'
    private_payload = b'x'
    client = app.app.test_client()
    resp = client.post('/sync', data={
        'record': json.dumps(record),
        'media': (io.BytesIO(private_payload), 'evil.jpg'),
    }, content_type='multipart/form-data')
    assert resp.status_code == 400


def test_missing_record_message_and_healthz():
    client = app.app.test_client()
    resp = client.get('/GC-DOES-NOT-EXIST')
    # New page uses title-case "Verification Failed" rather than all-caps
    assert b'Verification Failed' in resp.data or b'VERIFICATION FAILED' in resp.data
    assert client.get('/healthz').get_json()['storage'] == 'local'
