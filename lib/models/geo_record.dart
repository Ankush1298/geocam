class GeoRecord {
  final int protocolVersion;
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
  /// Ed25519 signature over canonical manifest.
  final String signature;
  /// SHA-256 of the exact stamped/exportable media bytes represented by this record.
  final String mediaSha256;
  /// Base64 Ed25519 public key corresponding to the device private key.
  final String publicKey;
  /// pending/synced/failed. Local captures remain usable when offline.
  final String syncStatus;
  /// Dimensions in "WIDTHxHEIGHT" format (e.g. "3024x4032").
  final String? imageDimensions;
  /// Fingerprint algorithm version (0 = none, 1 = grid-sha256-v1).
  final int fpVersion;
  /// SHA-256 digest of the canonical fingerprint manifest JSON.
  final String? fpSha256;
  /// Serialized canonical JSON manifest containing region hashes.
  final String? regionFingerprints;

  const GeoRecord({
    this.protocolVersion = 2,
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
    this.imageDimensions,
    this.fpVersion = 0,
    this.fpSha256,
    this.regionFingerprints,
  });

  bool get isVideo => mediaType == 'video';
  bool get hasCryptographicProof => signature.isNotEmpty && mediaSha256.isNotEmpty && publicKey.isNotEmpty;
  bool get hasFingerprint => fpVersion > 0 && (fpSha256?.isNotEmpty ?? false);

  Map<String, dynamic> toJson() => {
        'protocolVersion': protocolVersion,
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
        if (imageDimensions != null) 'imageDimensions': imageDimensions,
        'fpVersion': fpVersion,
        if (fpSha256 != null) 'fpSha256': fpSha256,
        if (regionFingerprints != null) 'regionFingerprints': regionFingerprints,
      };

  factory GeoRecord.fromJson(Map<String, dynamic> json) => GeoRecord(
        // Videos are only ever signed with the v2 canonical form. Builds that stored
        // them as v3 made the gallery and server reject their (valid) signatures.
        protocolVersion: json['mediaType'] == 'video' ? 2 : (json['protocolVersion'] as num?)?.toInt() ?? 2,
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
        imageDimensions: (json['imageDimensions'] as String?) ?? (json['image_dimensions'] as String?),
        fpVersion: (json['fpVersion'] as num?)?.toInt() ?? (json['fp_version'] as num?)?.toInt() ?? 0,
        fpSha256: (json['fpSha256'] as String?) ?? (json['fp_sha256'] as String?),
        regionFingerprints: (json['regionFingerprints'] as String?) ?? (json['region_fingerprints'] as String?),
      );
}
