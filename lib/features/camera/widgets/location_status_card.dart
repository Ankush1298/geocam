import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

class LocationStatusCard extends StatelessWidget {
  final Position? position;
  final String address;
  final String status;

  const LocationStatusCard({super.key, required this.position, required this.address, required this.status});

  Color get statusColor {
    final p = position;
    if (p == null) return Colors.orange;
    if (p.accuracy <= 25) return Colors.greenAccent;
    if (p.accuracy <= 100) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final p = position;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: statusColor.withValues(alpha: .35)),
      ),
      child: Row(children: [
        Icon(Icons.gps_fixed, size: 20, color: statusColor),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.w700)),
            const Spacer(),
            const Icon(Icons.chevron_right, size: 20, color: Colors.white54),
          ]),
          const SizedBox(height: 3),
          Text(
            p == null ? 'Waiting for a location fix…' : '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}  •  ±${p.accuracy.round()} m',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          if (address.isNotEmpty) Text(address, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 12)),
        ])),
      ]),
    );
  }
}
