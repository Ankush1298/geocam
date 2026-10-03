# GeoCam v0.5 architecture

This version intentionally keeps `main.dart` small and separates product responsibilities.

```text
GeoCam
│
├── App Shell
│   └── app/geocam_app.dart
│
├── Camera Feature
│   ├── features/camera/camera_page.dart
│   ├── features/camera/camera_controller.dart
│   └── features/camera/widgets/location_status_card.dart
│
├── Capture Feature
│   └── features/capture/result_page.dart
│
├── History Feature
│   ├── features/history/history_page.dart
│   └── features/history/history_detail_page.dart
│
├── Settings Feature
│   └── features/settings/settings_sheet.dart
│
├── Photo / Location / Storage Services
│   ├── services/photo_processor.dart
│   ├── services/location_service.dart
│   ├── services/geocoding_service.dart
│   ├── services/history_store.dart
│   └── services/record_id_service.dart
│
├── Models
│   ├── models/geo_record.dart
│   └── models/stamp_settings.dart
│
├── Core
│   └── core/theme/app_theme.dart
│
└── Platform helpers
    └── download_helper/
```

## Responsibility rule

UI files should render UI and coordinate navigation. Business logic belongs in controllers/services. Data structures belong in `models/`. This makes the later Android/iOS step much easier because the product logic does not need to be rewritten for each platform.

## Run on macOS

```bash
flutter pub get
flutter analyze
flutter run -d macos
```
