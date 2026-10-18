import os

# Legacy /sync is off by default in production; most existing tests exercise it.
os.environ.setdefault("GEOCAM_ENABLE_LEGACY_SYNC", "1")

# Rate limiting is covered by its own tests (which monkeypatch the limit); keep it off elsewhere.
os.environ["GEOCAM_ENV"] = "test"  # the only environment where rate limiting may be disabled
os.environ.setdefault("GEOCAM_RATE_LIMIT_PER_MIN", "0")
