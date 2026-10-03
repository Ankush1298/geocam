import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;

class GeocodingService {
  DateTime _lastLookup = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String> lookup(double latitude, double longitude) async {
    if (DateTime.now().difference(_lastLookup).inSeconds < 10) return '';
    _lastLookup = DateTime.now();

    if (!kIsWeb) {
      try {
        final marks = await placemarkFromCoordinates(latitude, longitude);
        if (marks.isNotEmpty) {
          final m = marks.first;
          final parts = [
            m.name,
            m.subLocality,
            m.locality,
            m.administrativeArea,
            m.postalCode,
            m.country,
          ]
              .where((s) => s != null && s.isNotEmpty)
              .map((s) => s!)
              .toSet();
          if (parts.isNotEmpty) return parts.join(', ');
        }
      } catch (_) {}
    }

    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=$latitude&lon=$longitude&zoom=18&addressdetails=1',
      );
      final response = await http.get(
        url,
        headers: const {'User-Agent': 'GeoCam/0.5'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data['address'] is Map) {
          final a = Map<String, dynamic>.from(data['address'] as Map);
          final parts = [
            a['road'],
            a['suburb'] ?? a['neighbourhood'],
            a['city'] ?? a['town'] ?? a['village'],
            a['state'],
            a['postcode'],
            a['country'],
          ]
              .where((s) => s != null && s.toString().isNotEmpty)
              .map((s) => s.toString())
              .toSet();
          if (parts.isNotEmpty) return parts.join(', ');
        }
      }
    } catch (_) {}

    return '';
  }
}
