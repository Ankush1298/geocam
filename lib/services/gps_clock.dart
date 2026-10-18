import 'package:geolocator/geolocator.dart';

/// Records how far the phone clock is from the time carried by live GPS fixes.
///
/// This is a clock-consistency check. It does not establish when a photo was taken.
///
/// Policy for a fix to count (unit-tested; behaviour of real GPS hardware is not):
///  * mocked fixes are ignored and reset tracking;
///  * the fix's own timestamp must be after 2020-01-01 and within [maxOffset] of the phone clock
///    in either direction. Smaller "future" timestamps are NOT rejected: a GPS fix ahead of the
///    phone clock is exactly what a phone clock running behind looks like, and that is the
///    condition this check exists to reveal. Real platform behaviour for slightly future-dated
///    fixes was not measured, so no tighter tolerance is claimed;
///  * freshness: each fix's timestamp must advance in step with a monotonic clock, within
///    [liveSlack] of the previous fix (tighter than the one-second fix interval, so a frozen
///    timestamp fails at once). Repeated, frozen, replayed or jumping timestamps never produce
///    a sample, and the first fix after a reset is never used on its own. The phone's wall
///    clock cannot decide freshness because the fix is compared against that very clock;
///  * accuracy is ignored: a weak fix still carries satellite time;
///  * a sample is only usable for [maxSampleAge] after it was received.
class GpsClockTracker {
  static const maxSampleAge = Duration(seconds: 30);
  static const warnThreshold = Duration(minutes: 2);
  static const maxOffset = Duration(days: 366);
  static const liveSlack = Duration(milliseconds: 750);
  static final earliestPlausibleFix = DateTime.utc(2020, 1, 1);

  final Stopwatch _mono = Stopwatch()..start();

  DateTime? _lastFixTime;
  int? _lastMonoMs;
  int? _offsetMs;
  DateTime? _receivedAt;
  int? _sampleMonoMs;

  /// Forget all history (call when the GPS stream is restarted): the next fix is a first fix.
  void reset() => _reset();

  void _reset() {
    _lastFixTime = null;
    _lastMonoMs = null;
    _offsetMs = null;
    _receivedAt = null;
    _sampleMonoMs = null;
  }

  /// [now] and [monoMs] exist so tests can drive time deterministically.
  void onFix(Position p, {DateTime? now, int? monoMs}) {
    if (p.isMocked) {
      _reset();
      return;
    }
    final received = (now ?? DateTime.now()).toUtc();
    final mono = monoMs ?? _mono.elapsedMilliseconds;
    final fixTime = p.timestamp.toUtc();
    final offset = received.difference(fixTime);

    if (fixTime.isBefore(earliestPlausibleFix) || offset.abs() > maxOffset) {
      _reset();
      return;
    }
    final prevFix = _lastFixTime, prevMono = _lastMonoMs;
    _lastFixTime = fixTime;
    _lastMonoMs = mono;
    if (prevFix == null || prevMono == null) {
      _offsetMs = null; // first fix: nothing to prove it is live yet
      _receivedAt = null;
      _sampleMonoMs = null;
      return;
    }
    final fixAdvance = fixTime.difference(prevFix).inMilliseconds;
    final monoAdvance = mono - prevMono;
    if (monoAdvance <= 0 || (fixAdvance - monoAdvance).abs() > liveSlack.inMilliseconds) {
      _offsetMs = null; // frozen, replayed, duplicated or jumping timestamps
      _receivedAt = null;
      _sampleMonoMs = null;
      return;
    }
    _offsetMs = offset.inMilliseconds;
    _receivedAt = received;
    _sampleMonoMs = mono;
  }

  /// Offset in ms (phone clock minus GPS time) to sign with a capture, or null when there is
  /// no live, recent sample.
  int? offsetFor(DateTime captureTime, {int? monoMs}) {
    final at = _receivedAt, sampleMono = _sampleMonoMs;
    if (at == null || sampleMono == null || _offsetMs == null) return null;
    if (captureTime.toUtc().difference(at).abs() > maxSampleAge) return null;
    final mono = monoMs ?? _mono.elapsedMilliseconds;
    if (mono - sampleMono > maxSampleAge.inMilliseconds) return null;
    return _offsetMs;
  }
}

/// Wording shared by the result screen. Always a consistency check, never a verified time.
String describeGpsClockOffset(int? offsetMs) {
  if (offsetMs == null) {
    return 'No GPS time reference was recorded for this capture. '
        'It needs a live satellite fix: take photos outdoors with Location on and wait for the GPS lock.';
  }
  final s = (offsetMs / 1000).round();
  final abs = s.abs();
  final span = abs >= 120 ? '${(abs / 60).round()} min' : '$abs s';
  if (offsetMs.abs() <= GpsClockTracker.warnThreshold.inMilliseconds) {
    return 'At capture the phone clock was within 2 minutes of GPS time ($span apart). '
        'Clock-consistency check only; it does not prove when the photo was taken.';
  }
  return 'At capture the phone clock was ${s > 0 ? "ahead of" : "behind"} GPS time by $span, '
      'so the captured time may be wrong. Consistency check only.';
}
