import 'package:flutter/material.dart';

import '../../models/stamp_settings.dart';

class SettingsSheet extends StatefulWidget {
  final StampSettings initial;
  const SettingsSheet({super.key, required this.initial});

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late StampSettings settings;
  late TextEditingController customController;

  @override
  void initState() {
    super.initState();
    settings = widget.initial.copy();
    customController = TextEditingController(text: settings.customText);
  }

  @override
  void dispose() {
    customController.dispose();
    super.dispose();
  }

  Widget _switch(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile.adaptive(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 14, 16, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Stamp settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 4),
          const Text('Choose what appears on every GeoCam photo and video.', style: TextStyle(color: Colors.white60)),
          const SizedBox(height: 12),
          _switch('Coordinates', 'Latitude and longitude', settings.showCoordinates, (v) => setState(() => settings.showCoordinates = v)),
          _switch('Address', 'Reverse-geocoded location when available', settings.showAddress, (v) => setState(() => settings.showAddress = v)),
          _switch('Date & time', 'Capture date and time', settings.showDateTime, (v) => setState(() => settings.showDateTime = v)),
          _switch('GPS accuracy', 'Estimated location accuracy', settings.showAccuracy, (v) => setState(() => settings.showAccuracy = v)),
          _switch('QR code', 'Machine-readable GeoCam location record', settings.showQr, (v) => setState(() => settings.showQr = v)),
          _switch('Map link in QR', 'Tap-to-open Maps link inside the QR (turn off for a less dense QR)', settings.qrMapLink, (v) => setState(() => settings.qrMapLink = v)),
          _switch('Pixel-Embedded Stamp', 'Burn location, date/time and QR into the photo/video pixels', settings.pixelEmbeddedStamps, (v) => setState(() => settings.pixelEmbeddedStamps = v)),
          _switch('Cloud verification', 'Upload the signed media to the GeoCam server so friends can verify it from the QR', settings.cloudVerification, (v) => setState(() => settings.cloudVerification = v)),
          const SizedBox(height: 10),
          TextField(
            controller: customController,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Custom stamp text',
              hintText: 'e.g. SITE INSPECTION',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => settings.customText = v,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, settings),
            icon: const Icon(Icons.check),
            label: const Text('Save stamp settings'),
          ),
        ]),
      ),
    );
  }
}
