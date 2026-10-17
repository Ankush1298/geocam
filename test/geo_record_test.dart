import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/models/geo_record.dart';

void main() {
  test('syncStatus update keeps v3 fields (regression: gallery showed Tampered)', () {
    final r = GeoRecord(
      protocolVersion: 3, id: 'GC-1', stampedPath: 'a', originalPath: 'a',
      timestamp: DateTime.utc(2026, 1, 1), latitude: 1, longitude: 2, accuracy: 3,
      altitude: 4, address: 'x', signature: 's', mediaSha256: 'h', publicKey: 'k',
      imageDimensions: '10x10', fpVersion: 1, fpSha256: 'f', regionFingerprints: '{}',
    );
    final u = GeoRecord.fromJson({...r.toJson(), 'syncStatus': 'synced'});
    expect(u.syncStatus, 'synced');
    expect(u.protocolVersion, 3);
    expect(u.imageDimensions, '10x10');
    expect(u.fpVersion, 1);
    expect(u.fpSha256, 'f');
    expect(u.regionFingerprints, '{}');
  });
}
