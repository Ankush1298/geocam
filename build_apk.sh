#!/usr/bin/env bash
set -euo pipefail

# Build small device-specific release APKs instead of one large universal APK.
# Set GEOCAM_VERIFICATION_URL when the verifier endpoint changes.
SERVER_URL="${GEOCAM_VERIFICATION_URL:-https://geocam-server.onrender.com}"

flutter clean
flutter pub get
flutter analyze

rm -rf build/app/outputs/flutter-apk build/symbols
flutter build apk   --release   --split-per-abi   --split-debug-info=build/symbols   --dart-define=GEOCAM_VERIFICATION_URL="$SERVER_URL"

printf '\nDevice-specific APKs:\n'
find build/app/outputs/flutter-apk -maxdepth 1 -type f -name 'app-*-release.apk' -print | sort
printf '\nSymbols (keep separately; do not ship with APK): %s\n' "$(pwd)/build/symbols"
