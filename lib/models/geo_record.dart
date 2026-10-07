class GeoRecord {
  final String id;
  final String stampedPath;
  final String originalPath;
  final String mediaType;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final double? accuracy;
  final double? altitude;
  final String address;
  /// Ed25519 signature over the canonical metadata + final media SHA-256.
  final String signature;
  /// SHA-256 of the exact stamped/exportable media bytes represented by this record.
  final String mediaSha256;
  /// Base64 Ed25519 public key corresponding to the device private key.
  final String publicKey;
  /// pending/synced/failed. Local captures remain usable when offline.
  final String syncStatus;

  const GeoRecord({
    required this.id,
    required this.stampedPath,
    required this.originalPath,
    this.mediaType = 'photo',
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.altitude,
    required this.address,
    this.signature = '',
    this.mediaSha256 = '',
    this.publicKey = '',
    this.syncStatus = 'pending',
  });

  bool get isVideo => mediaType == 'video';
  bool get hasCryptographicProof => signature.isNotEmpty && mediaSha256.isNotEmpty && publicKey.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'protocolVersion': 2,
        'id': id,
        'stampedPath': stampedPath,
        'originalPath': originalPath,
        'mediaType': mediaType,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'altitude': altitude,
        'address': address,
        'signature': signature,
        'mediaSha256': mediaSha256,
        'publicKey': publicKey,
        'syncStatus': syncStatus,
      };

  factory GeoRecord.fromJson(Map<String, dynamic> json) => GeoRecord(
        id: json['id'] as String,
        stampedPath: json['stampedPath'] as String,
        originalPath: json['originalPath'] as String,
        mediaType: (json['mediaType'] as String?) ?? 'photo',
        timestamp: DateTime.parse(json['timestamp'] as String),
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        accuracy: (json['accuracy'] as num?)?.toDouble(),
        altitude: (json['altitude'] as num?)?.toDouble(),
        address: (json['address'] as String?) ?? '',
        // Read old `hash` records so existing history doesn't crash after upgrade.
        signature: (json['signature'] as String?) ?? (json['hash'] as String?) ?? '',
        mediaSha256: (json['mediaSha256'] as String?) ?? '',
        publicKey: (json['publicKey'] as String?) ?? (json['public_key'] as String?) ?? '',
        syncStatus: (json['syncStatus'] as String?) ?? 'pending',
      );
}
