import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/services/photo_processor.dart';
import 'package:geocam/services/time_format.dart';

void main() {
  test('UTC instants are shown in IST (UTC+05:30)', () {
    expect(formatIst(DateTime.utc(2026, 10, 24, 0, 0, 0)), '24/10/2026 05:30:00 IST');
    expect(formatIst(DateTime.utc(2026, 10, 23, 18, 29, 59)), '23/10/2026 23:59:59 IST');
  });

  test('crossing midnight and the year', () {
    expect(formatIst(DateTime.utc(2026, 12, 31, 20, 0, 0)), '01/01/2027 01:30:00 IST');
  });

  test('the phone time zone does not matter: local and UTC forms of one instant agree', () {
    final utc = DateTime.utc(2026, 3, 5, 7, 8, 9);
    expect(formatIst(utc.toLocal()), formatIst(utc));
    expect(formatIst(DateTime.parse('2026-03-05T12:38:09+05:30')), '05/03/2026 12:38:09 IST');
  });

  test('the photo stamp, gallery, result and server views use the same text', () {
    final t = DateTime.utc(2026, 10, 23, 18, 55, 4);
    expect(PhotoProcessor.formatDateTime(t), formatIst(t));
    expect(formatIstText('2026-10-23T18:55:04.123456+00:00'), formatIst(t));
    expect(formatIstText('2026-10-23T18:55:04Z'), formatIst(t));
    expect(formatIstText('2026-10-23T18:55:04'), formatIst(t), reason: 'no zone means UTC in GeoCam');
  });

  test('missing or non-time text is not invented', () {
    expect(formatIstText(null), '—');
    expect(formatIstText(null, ifMissing: 'Not recorded'), 'Not recorded');
    expect(formatIstText('unknown'), 'unknown');
  });
}
