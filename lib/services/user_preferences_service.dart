import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/saved_location.dart';

class UserPreferencesService {
  static final UserPreferencesService _instance = UserPreferencesService._internal();
  factory UserPreferencesService() => _instance;
  UserPreferencesService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Get current user's preferences document reference
  DocumentReference? get _userPreferencesDoc {
    final user = _auth.currentUser;
    if (user != null) {
      return _firestore.collection('users').doc(user.uid).collection('preferences').doc('default_locations');
    }
    return null;
  }

  // Save default home location
  Future<bool> saveDefaultHomeLocation(SavedLocation location) async {
    try {
      final doc = _userPreferencesDoc;
      if (doc == null) {
        throw Exception('User not authenticated');
      }

      await doc.set({
        'defaultHomeLocationId': location.id,
        'defaultHomeName': location.name,
        'defaultHomeAddress': location.address,
        'defaultHomeLatitude': location.latitude,
        'defaultHomeLongitude': location.longitude,
        'defaultHomeType': location.type,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      print('✅ Default home location saved: ${location.name}');
      return true;
    } catch (e) {
      print('❌ Error saving default home location: $e');
      return false;
    }
  }

  // Save default work location
  Future<bool> saveDefaultWorkLocation(SavedLocation location) async {
    try {
      final doc = _userPreferencesDoc;
      if (doc == null) {
        throw Exception('User not authenticated');
      }

      await doc.set({
        'defaultWorkLocationId': location.id,
        'defaultWorkName': location.name,
        'defaultWorkAddress': location.address,
        'defaultWorkLatitude': location.latitude,
        'defaultWorkLongitude': location.longitude,
        'defaultWorkType': location.type,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      print('✅ Default work location saved: ${location.name}');
      return true;
    } catch (e) {
      print('❌ Error saving default work location: $e');
      return false;
    }
  }

  // Get default home location
  Future<SavedLocation?> getDefaultHomeLocation() async {
    try {
      final doc = _userPreferencesDoc;
      if (doc == null) {
        return null;
      }

      final docSnapshot = await doc.get();
      if (docSnapshot.exists && docSnapshot.data() != null) {
        final data = docSnapshot.data() as Map<String, dynamic>;
        
        if (data['defaultHomeLocationId'] != null) {
          return SavedLocation(
            id: data['defaultHomeLocationId'],
            name: data['defaultHomeName'] ?? '',
            address: data['defaultHomeAddress'] ?? '',
            latitude: (data['defaultHomeLatitude'] ?? 0.0).toDouble(),
            longitude: (data['defaultHomeLongitude'] ?? 0.0).toDouble(),
            type: data['defaultHomeType'] ?? 'home',
            createdAt: DateTime.now(), // This will be overridden by the actual saved location
            isOsrmValidated: true, // Assume validated since it was saved
          );
        }
      }
      return null;
    } catch (e) {
      print('❌ Error getting default home location: $e');
      return null;
    }
  }

  // Get default work location
  Future<SavedLocation?> getDefaultWorkLocation() async {
    try {
      final doc = _userPreferencesDoc;
      if (doc == null) {
        return null;
      }

      final docSnapshot = await doc.get();
      if (docSnapshot.exists && docSnapshot.data() != null) {
        final data = docSnapshot.data() as Map<String, dynamic>;
        
        if (data['defaultWorkLocationId'] != null) {
          return SavedLocation(
            id: data['defaultWorkLocationId'],
            name: data['defaultWorkName'] ?? '',
            address: data['defaultWorkAddress'] ?? '',
            latitude: (data['defaultWorkLatitude'] ?? 0.0).toDouble(),
            longitude: (data['defaultWorkLongitude'] ?? 0.0).toDouble(),
            type: data['defaultWorkType'] ?? 'office',
            createdAt: DateTime.now(), // This will be overridden by the actual saved location
            isOsrmValidated: true, // Assume validated since it was saved
          );
        }
      }
      return null;
    } catch (e) {
      print('❌ Error getting default work location: $e');
      return null;
    }
  }

  // Clear default home location
  Future<bool> clearDefaultHomeLocation() async {
    try {
      final doc = _userPreferencesDoc;
      if (doc == null) {
        throw Exception('User not authenticated');
      }

      await doc.update({
        'defaultHomeLocationId': FieldValue.delete(),
        'defaultHomeName': FieldValue.delete(),
        'defaultHomeAddress': FieldValue.delete(),
        'defaultHomeLatitude': FieldValue.delete(),
        'defaultHomeLongitude': FieldValue.delete(),
        'defaultHomeType': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      print('✅ Default home location cleared');
      return true;
    } catch (e) {
      print('❌ Error clearing default home location: $e');
      return false;
    }
  }

  // Clear default work location
  Future<bool> clearDefaultWorkLocation() async {
    try {
      final doc = _userPreferencesDoc;
      if (doc == null) {
        throw Exception('User not authenticated');
      }

      await doc.update({
        'defaultWorkLocationId': FieldValue.delete(),
        'defaultWorkName': FieldValue.delete(),
        'defaultWorkAddress': FieldValue.delete(),
        'defaultWorkLatitude': FieldValue.delete(),
        'defaultWorkLongitude': FieldValue.delete(),
        'defaultWorkType': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      print('✅ Default work location cleared');
      return true;
    } catch (e) {
      print('❌ Error clearing default work location: $e');
      return false;
    }
  }

  // Get all default locations
  Future<Map<String, SavedLocation?>> getDefaultLocations() async {
    try {
      final home = await getDefaultHomeLocation();
      final work = await getDefaultWorkLocation();
      
      return {
        'home': home,
        'work': work,
      };
    } catch (e) {
      print('❌ Error getting default locations: $e');
      return {
        'home': null,
        'work': null,
      };
    }
  }

  // Check if default locations are set
  Future<bool> hasDefaultLocations() async {
    try {
      final defaults = await getDefaultLocations();
      return defaults['home'] != null || defaults['work'] != null;
    } catch (e) {
      return false;
    }
  }
}