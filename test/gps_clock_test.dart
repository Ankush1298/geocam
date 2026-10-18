import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/services/gps_clock.dart';
import 'package:geolocator/geolocator.dart';

/// Policy tests with fake time. They show the rules are applied; they do not show how real
/// GPS hardware or the Android location provider behaves (that needs a device test).
void main() {
  final base = DateTime.utc(2026, 10, 18, 12, 0, 0);

  Position fix(DateTime t, {double accuracy = 5, bool mocked = false}) => Position(
        longitude: 1,
        latitude: 2,
        timestamp: t,
        accuracy: accuracy,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
        isMocked: mocked,
      );

  /// Feeds [n] live one-second fixes where the phone clock is [ahead] of GPS time.
  GpsClockTracker live({Duration ahead = Duration.zero, int n = 3, double accuracy = 5}) {
    final t = GpsClockTracker();
    for (var i = 0; i < n; i++) {
      final gps = base.add(Duration(seconds: i));
      t.onFix(fix(gps, accuracy: accuracy), now: gps.add(ahead), monoMs: 1000 * i);
    }
    return t;
  }

  final lastNow = base.add(const Duration(seconds: 2));

  test('valid live fixes give the offset (phone ahead is positive)', () {
    expect(live(ahead: const Duration(seconds: 90)).offsetFor(lastNow.add(const Duration(seconds: 90)), monoMs: 2500), 90000);
    expect(live(ahead: const Duration(seconds: -300)).offsetFor(lastNow.subtract(const Duration(seconds: 300)), monoMs: 2500), -300000);
    expect(live().offsetFor(lastNow, monoMs: 2500), 0);
  });

  test('GPS accuracy does not matter (weak and strong fixes both count)', () {
    for (final acc in [3.0, 40.0, 900.0, 5000.0]) {
      expect(live(accuracy: acc).offsetFor(lastNow, monoMs: 2500), 0, reason: 'accuracy $acc');
    }
  });

  test('missing: no fixes, or a single first fix, is not a reference', () {
    expect(GpsClockTracker().offsetFor(base, monoMs: 0), isNull);
    final t = GpsClockTracker()..onFix(fix(base), now: base, monoMs: 0);
    expect(t.offsetFor(base, monoMs: 100), isNull);
  });

  test('mocked fixes are ignored and reset tracking', () {
    final t = live();
    t.onFix(fix(base.add(const Duration(seconds: 3)), mocked: true), now: base.add(const Duration(seconds: 3)), monoMs: 3000);
    expect(t.offsetFor(base.add(const Duration(seconds: 3)), monoMs: 3100), isNull);
    // after a mocked fix two further live fixes are needed again
    t.onFix(fix(base.add(const Duration(seconds: 4))), now: base.add(const Duration(seconds: 4)), monoMs: 4000);
    expect(t.offsetFor(base.add(const Duration(seconds: 4)), monoMs: 4100), isNull);
    t.onFix(fix(base.add(const Duration(seconds: 5))), now: base.add(const Duration(seconds: 5)), monoMs: 5000);
    expect(t.offsetFor(base.add(const Duration(seconds: 5)), monoMs: 5100), 0);
  });

  test('reset (stream restart): old samples are dropped and the next fix is a first fix again', () {
    final t = live();
    t.reset();
    expect(t.offsetFor(lastNow, monoMs: 2500), isNull);
    t.onFix(fix(base.add(const Duration(seconds: 3))), now: base.add(const Duration(seconds: 3)), monoMs: 3000);
    expect(t.offsetFor(base.add(const Duration(seconds: 3)), monoMs: 3100), isNull);
    t.onFix(fix(base.add(const Duration(seconds: 4))), now: base.add(const Duration(seconds: 4)), monoMs: 4000);
    expect(t.offsetFor(base.add(const Duration(seconds: 4)), monoMs: 4100), 0);
  });

  test('stale: a frozen or repeated fix timestamp is not live', () {
    final t = GpsClockTracker();
    for (var i = 0; i < 4; i++) {
      t.onFix(fix(base), now: base.add(Duration(seconds: i)), monoMs: 1000 * i); // same timestamp every second
    }
    expect(t.offsetFor(base.add(const Duration(seconds: 3)), monoMs: 3100), isNull);
  });

  test('stale: a replayed older fix breaks liveness', () {
    final t = live();
    t.onFix(fix(base.subtract(const Duration(minutes: 5))), now: base.add(const Duration(seconds: 3)), monoMs: 3000);
    expect(t.offsetFor(base.add(const Duration(seconds: 3)), monoMs: 3100), isNull);
  });

  test('stale: a sample older than 30 seconds is dropped (monotonic and wall clock)', () {
    final t = live();
    expect(t.offsetFor(lastNow, monoMs: 2000 + 30001), isNull);
    expect(t.offsetFor(lastNow, monoMs: 2000 + 29000), 0);
    expect(t.offsetFor(lastNow.add(const Duration(seconds: 31)), monoMs: 2500), isNull);
  });

  test('timestamps that jump instead of advancing with real time are not live', () {
    final t = GpsClockTracker();
    t.onFix(fix(base), now: base, monoMs: 0);
    t.onFix(fix(base.add(const Duration(seconds: 60))), now: base.add(const Duration(seconds: 1)), monoMs: 1000);
    expect(t.offsetFor(base.add(const Duration(seconds: 1)), monoMs: 1100), isNull);
  });

  test('future-dated: beyond 366 days is rejected, up to that bound is reported (phone clock behind)', () {
    final t = GpsClockTracker();
    final far = base.add(const Duration(days: 400));
    t.onFix(fix(far), now: base, monoMs: 0);
    t.onFix(fix(far.add(const Duration(seconds: 1))), now: base.add(const Duration(seconds: 1)), monoMs: 1000);
    expect(t.offsetFor(base.add(const Duration(seconds: 1)), monoMs: 1100), isNull);

    final behind = GpsClockTracker();
    final gpsAhead = base.add(const Duration(hours: 3));
    behind.onFix(fix(gpsAhead), now: base, monoMs: 0);
    behind.onFix(fix(gpsAhead.add(const Duration(seconds: 1))), now: base.add(const Duration(seconds: 1)), monoMs: 1000);
    expect(behind.offsetFor(base.add(const Duration(seconds: 1)), monoMs: 1100), -3 * 3600 * 1000);
  });

  test('far-past fixes (before 2020 or more than 366 days old) are rejected', () {
    for (final gps in [DateTime.utc(2019, 12, 31), base.subtract(const Duration(days: 400))]) {
      final t = GpsClockTracker();
      t.onFix(fix(gps), now: base, monoMs: 0);
      t.onFix(fix(gps.add(const Duration(seconds: 1))), now: base.add(const Duration(seconds: 1)), monoMs: 1000);
      expect(t.offsetFor(base.add(const Duration(seconds: 1)), monoMs: 1100), isNull, reason: '$gps');
    }
  });

  test('warning threshold stays at two minutes', () {
    expect(GpsClockTracker.warnThreshold, const Duration(minutes: 2));
    expect(describeGpsClockOffset(120000), contains('within 2 minutes'));
    expect(describeGpsClockOffset(120001), contains('may be wrong'));
  });

  test('wording is a consistency check, never a verified capture time', () {
    for (final v in [null, 0, 1500, -90000, 3 * 3600 * 1000, -600000]) {
      final text = describeGpsClockOffset(v).toLowerCase();
      expect(text, isNot(contains('matched')));
      expect(text, isNot(contains('verified')));
      expect(text, isNot(contains('proves when')));
    }
    expect(describeGpsClockOffset(1500), contains('does not prove when the photo was taken'));
    expect(describeGpsClockOffset(1500), contains('Clock-consistency check only'));
    expect(describeGpsClockOffset(null), contains('No GPS time reference'));
    expect(describeGpsClockOffset(3 * 3600 * 1000), contains('ahead of'));
    expect(describeGpsClockOffset(-600000), contains('behind'));
  });
}
