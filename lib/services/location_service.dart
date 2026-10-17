import 'dart:async';

import 'package:geolocator/geolocator.dart';

class LocationService {
  static const maxCachedAge = Duration(minutes: 2);

  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    return permission != LocationPermission.denied &&
        permission != LocationPermission.deniedForever;
  }

  Future<Position?> getInitialPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    if (!await ensurePermission()) return null;

    // A cached fix is only used if it is recent; otherwise a stale location
    // from hours ago would be signed as the capture location.
    final cached = await Geolocator.getLastKnownPosition();
    if (cached != null &&
        DateTime.now().difference(cached.timestamp).abs() <= maxCachedAge) {
      return cached;
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          timeLimit: Duration(seconds: 20),
        ),
      );
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Position?> refreshPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    if (!await ensurePermission()) return null;

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          timeLimit: Duration(seconds: 20),
        ),
      );
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> isLocationServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  Future<LocationPermission> permission() => Geolocator.checkPermission();

  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  Stream<Position> watch() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
      ),
    );
  }
}
