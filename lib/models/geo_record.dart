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
  /// HMAC-SHA256 truncated hex signature produced at capture time.
  /// Empty string means the record pre-dates the signing feature.
  final String hash;

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
    this.hash = '',
  });

  bool get isVideo => mediaType == 'video';

  Map<String, dynamic> toJson() => {
        'id': id,
        'stampedPath': stampedPath,
        'originalPath': originalPath,
        'mediaType': mediaType,
        'timestamp': timestamp.toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'altitude': altitude,
        'address': address,
        'hash': hash,
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
        hash: (json['hash'] as String?) ?? '',
      );
}
