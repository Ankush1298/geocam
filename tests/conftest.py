import os

# Legacy /sync is off by default in production; most existing tests exercise it.
os.environ.setdefault("GEOCAM_ENABLE_LEGACY_SYNC", "1")
