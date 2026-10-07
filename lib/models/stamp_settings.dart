import 'package:shared_preferences/shared_preferences.dart';

class StampSettings {
  bool showCoordinates;
  bool showAddress;
  bool showDateTime;
  bool showAccuracy;
  bool showQr;
  bool qrMapLink;
  bool pixelEmbeddedStamps;
  bool cloudVerification;
  String customText;

  StampSettings({
    this.showCoordinates = true,
    this.showAddress = true,
    this.showDateTime = true,
    this.showAccuracy = true,
    this.showQr = true,
    this.qrMapLink = true,
    this.pixelEmbeddedStamps = true,
    this.cloudVerification = true,
    this.customText = '',
  });

  StampSettings copy() => StampSettings(
        showCoordinates: showCoordinates,
        showAddress: showAddress,
        showDateTime: showDateTime,
        showAccuracy: showAccuracy,
        showQr: showQr,
        qrMapLink: qrMapLink,
        pixelEmbeddedStamps: pixelEmbeddedStamps,
        cloudVerification: cloudVerification,
        customText: customText,
      );

  static Future<StampSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return StampSettings(
      showCoordinates: p.getBool('stamp.coordinates') ?? true,
      showAddress: p.getBool('stamp.address') ?? true,
      showDateTime: p.getBool('stamp.datetime') ?? true,
      showAccuracy: p.getBool('stamp.accuracy') ?? true,
      showQr: p.getBool('stamp.qr') ?? true,
      qrMapLink: p.getBool('stamp.qrMapLink') ?? true,
      pixelEmbeddedStamps: p.getBool('stamp.pixelEmbedded') ?? true,
      cloudVerification: p.getBool('stamp.cloudVerification') ?? true,
      customText: p.getString('stamp.custom') ?? '',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('stamp.coordinates', showCoordinates);
    await p.setBool('stamp.address', showAddress);
    await p.setBool('stamp.datetime', showDateTime);
    await p.setBool('stamp.accuracy', showAccuracy);
    await p.setBool('stamp.qr', showQr);
    await p.setBool('stamp.qrMapLink', qrMapLink);
    await p.setBool('stamp.pixelEmbedded', pixelEmbeddedStamps);
    await p.setBool('stamp.cloudVerification', cloudVerification);
    await p.setString('stamp.custom', customText);
  }
}
