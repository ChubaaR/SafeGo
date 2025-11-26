import 'package:latlong2/latlong.dart';

class SavedLocation {
  final String id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final String type; // 'home', 'office', 'other'
  final DateTime createdAt;
  final bool isOsrmValidated;

  SavedLocation({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.type,
    required this.createdAt,
    this.isOsrmValidated = false,
  });

  // Convert to LatLng for map operations
  LatLng get coordinates => LatLng(latitude, longitude);

  // Convert to Map for Firebase storage
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'type': type,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'isOsrmValidated': isOsrmValidated,
    };
  }

  // Create from Firebase document
  factory SavedLocation.fromMap(Map<String, dynamic> map, String documentId) {
    return SavedLocation(
      id: documentId,
      name: map['name'] ?? '',
      address: map['address'] ?? '',
      latitude: (map['latitude'] ?? 0.0).toDouble(),
      longitude: (map['longitude'] ?? 0.0).toDouble(),
      type: map['type'] ?? 'other',
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] ?? 0),
      isOsrmValidated: map['isOsrmValidated'] ?? false,
    );
  }

  // Create a copy with updated fields
  SavedLocation copyWith({
    String? name,
    String? address,
    double? latitude,
    double? longitude,
    String? type,
    bool? isOsrmValidated,
  }) {
    return SavedLocation(
      id: id,
      name: name ?? this.name,
      address: address ?? this.address,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      type: type ?? this.type,
      createdAt: createdAt,
      isOsrmValidated: isOsrmValidated ?? this.isOsrmValidated,
    );
  }

  @override
  String toString() {
    return 'SavedLocation{id: $id, name: $name, address: $address, type: $type}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedLocation &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}