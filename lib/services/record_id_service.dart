import 'dart:math';

class RecordIdService {
  static String create(DateTime now) {
    final random = Random.secure()
        .nextInt(0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    return 'GC-${now.millisecondsSinceEpoch.toRadixString(36).toUpperCase()}-$random';
  }
}
