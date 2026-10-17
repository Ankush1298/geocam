import time
import base64
import hashlib
import json
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
import app

def benchmark():
    private = Ed25519PrivateKey.generate()
    public = private.public_key()

    payload = b"dummy-media-bytes" * (1024 * 1024) # 15 MB approx

    # 1. SHA-256 time
    t0 = time.time()
    media_sha256 = hashlib.sha256(payload).hexdigest()
    t1 = time.time()

    record = {
        "protocolVersion": 2,
        "id": "GC-BENCH-001",
        "timestamp": "2026-10-08T15:37:46.000000Z",
        "latitude": 25.033919,
        "longitude": 74.634770,
        "accuracy": 50.8,
        "altitude": 383.3,
        "address": "Test, India",
        "mediaType": "photo",
        "mediaSha256": media_sha256,
        "publicKey": base64.b64encode(public.public_bytes_raw()).decode(),
    }

    # 2. Canonicalization and signing time
    t2 = time.time()
    canonical_data = app.canonical(record)
    signature = private.sign(canonical_data)
    record["signature"] = base64.b64encode(signature).decode()
    t3 = time.time()

    # 3. Verification time
    t4 = time.time()
    is_valid = app.verify_signature(record)
    t5 = time.time()

    # Results
    print(f"File Size: {len(payload)/1024/1024:.2f} MB")
    print(f"Hashing Time (SHA-256): {(t1-t0)*1000:.2f} ms")
    print(f"Signature Generation Time: {(t3-t2)*1000:.2f} ms")
    print(f"Verification Time: {(t5-t4)*1000:.2f} ms")

    metadata_json = json.dumps(record)
    print(f"Metadata Storage Overhead: {len(metadata_json)} bytes")

if __name__ == '__main__':
    benchmark()
