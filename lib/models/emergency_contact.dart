import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';

// Data model for Emergency Contact
class EmergencyContact {
  final String id;
  final String name;
  final String phoneNumber;
  final String relationship;
  final File? profileImage;
  final String? profileImageUrl; 
  final bool allowShareLiveLocation;
  final bool notifyWhenSafelyArrived;
  final bool shareLiveLocationDuringSOS;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? email;

  EmergencyContact({
    required this.id,
    required this.name,
    required this.phoneNumber,
    required this.relationship,
    this.email,
    this.profileImage,
    this.profileImageUrl,
    this.allowShareLiveLocation = false,
    this.notifyWhenSafelyArrived = false,
    this.shareLiveLocationDuringSOS = false,
    this.createdAt,
    this.updatedAt,
  });

  // Convert EmergencyContact to Map for Firebase
  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'phoneNumber': phoneNumber,
      'email': email,
      'relationship': relationship,
      'profileImageUrl': profileImageUrl,
      'allowShareLiveLocation': allowShareLiveLocation,
      'notifyWhenSafelyArrived': notifyWhenSafelyArrived,
      'shareLiveLocationDuringSOS': shareLiveLocationDuringSOS,
      'createdAt': createdAt ?? FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  // Create EmergencyContact from Firebase document
  factory EmergencyContact.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    final data = snapshot.data()!;
    return EmergencyContact(
      id: snapshot.id,
      name: data['name'] ?? '',
      phoneNumber: data['phoneNumber'] ?? '',
  email: data['email'],
      relationship: data['relationship'] ?? '',
      profileImageUrl: data['profileImageUrl'],
      allowShareLiveLocation: data['allowShareLiveLocation'] ?? false,
      notifyWhenSafelyArrived: data['notifyWhenSafelyArrived'] ?? false,
      shareLiveLocationDuringSOS: data['shareLiveLocationDuringSOS'] ?? false,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  // Copy with method for updates
  EmergencyContact copyWith({
    String? id,
    String? name,
    String? phoneNumber,
    String? relationship,
    String? email,
    File? profileImage,
    String? profileImageUrl,
    bool? allowShareLiveLocation,
    bool? notifyWhenSafelyArrived,
    bool? shareLiveLocationDuringSOS,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return EmergencyContact(
      id: id ?? this.id,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      email: email ?? this.email,
      relationship: relationship ?? this.relationship,
      profileImage: profileImage ?? this.profileImage,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      allowShareLiveLocation: allowShareLiveLocation ?? this.allowShareLiveLocation,
      notifyWhenSafelyArrived: notifyWhenSafelyArrived ?? this.notifyWhenSafelyArrived,
      shareLiveLocationDuringSOS: shareLiveLocationDuringSOS ?? this.shareLiveLocationDuringSOS,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}