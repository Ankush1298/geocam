/// One way to show a time everywhere in GeoCam: Indian Standard Time (UTC+05:30, no daylight
/// saving), `dd/MM/yyyy HH:mm:ss IST`, whatever time zone the phone is set to.
///
/// Records are stored and signed in UTC; this is display only and never changes a signed value.
const istOffset = Duration(hours: 5, minutes: 30);

String formatIst(DateTime t) {
  final ist = t.toUtc().add(istOffset);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(ist.day)}/${two(ist.month)}/${ist.year} '
      '${two(ist.hour)}:${two(ist.minute)}:${two(ist.second)} IST';
}

/// Formats an ISO-8601 timestamp received as text (for example from the server). Text that is not
/// a timestamp is returned unchanged, so nothing is hidden or invented.
String formatIstText(Object? iso, {String ifMissing = '—'}) {
  if (iso == null) return ifMissing;
  final text = iso.toString();
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return text;
  // A time with no zone is UTC in GeoCam (the server and phone both send UTC).
  final utc = parsed.isUtc ? parsed : DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.minute, parsed.second, parsed.millisecond);
  return formatIst(utc);
}
