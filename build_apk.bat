@echo off
setlocal
if "%GEOCAM_VERIFICATION_URL%"=="" set "GEOCAM_VERIFICATION_URL=https://geocam-server.onrender.com"

flutter clean
flutter pub get
flutter analyze
if exist build\app\outputs\flutter-apk rmdir /s /q build\app\outputs\flutter-apk
if exist build\symbols rmdir /s /q build\symbols

flutter build apk --release --split-per-abi --split-debug-info=build\symbols --dart-define=GEOCAM_VERIFICATION_URL=%GEOCAM_VERIFICATION_URL%

echo.
echo Device-specific APKs are in:
echo buildpp\outputslutter-apk
endlocal
