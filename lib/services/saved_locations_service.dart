import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:math' as math;
import '../models/saved_location.dart';

class SavedLocationsService {
  static final SavedLocationsService _instance = SavedLocationsService._internal();
  factory SavedLocationsService() => _instance;
  SavedLocationsService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Get current user's document reference
  DocumentReference? get _userDoc {
    final user = _auth.currentUser;
    if (user != null) {
      return _firestore.collection('users').doc(user.uid);
    }
    return null;
  }

  // Get saved locations collection for current user
  CollectionReference? get _savedLocationsCollection {
    final userDoc = _userDoc;
    if (userDoc != null) {
      return userDoc.collection('saved_locations');
    }
    return null;
  }

  // Save a new location
  Future<String?> saveLocation({
    required String name,
    required String address,
    required double latitude,
    required double longitude,
    required String type,
  }) async {
    try {
      final collection = _savedLocationsCollection;
      if (collection == null) {
        throw Exception('User not authenticated');
      }

      // Validate location with OSRM first
      bool isValidated = await _validateWithOSRM(latitude, longitude);

      final savedLocation = SavedLocation(
        id: '', // Will be set by Firestore
        name: name,
        address: address,
        latitude: latitude,
        longitude: longitude,
        type: type,
        createdAt: DateTime.now(),
        isOsrmValidated: isValidated,
      );

      final docRef = await collection.add(savedLocation.toMap());
      return docRef.id;
    } catch (e) {
      print('Error saving location: $e');
      return null;
    }
  }

  // Get all saved locations for current user
  Future<List<SavedLocation>> getSavedLocations() async {
    try {
      final collection = _savedLocationsCollection;
      if (collection == null) {
        return [];
      }

      final querySnapshot = await collection
          .orderBy('createdAt', descending: true)
          .get();

      return querySnapshot.docs.map((doc) {
        return SavedLocation.fromMap(
          doc.data() as Map<String, dynamic>,
          doc.id,
        );
      }).toList();
    } catch (e) {
      print('Error getting saved locations: $e');
      return [];
    }
  }

  // Get saved locations by type
  Future<List<SavedLocation>> getSavedLocationsByType(String type) async {
    try {
      final collection = _savedLocationsCollection;
      if (collection == null) {
        return [];
      }

      final querySnapshot = await collection
          .where('type', isEqualTo: type)
          .orderBy('createdAt', descending: true)
          .get();

      return querySnapshot.docs.map((doc) {
        return SavedLocation.fromMap(
          doc.data() as Map<String, dynamic>,
          doc.id,
        );
      }).toList();
    } catch (e) {
      print('Error getting saved locations by type: $e');
      return [];
    }
  }

  // Update a saved location
  Future<bool> updateLocation(String locationId, {
    String? name,
    String? address,
    double? latitude,
    double? longitude,
    String? type,
  }) async {
    try {
      final collection = _savedLocationsCollection;
      if (collection == null) {
        return false;
      }

      Map<String, dynamic> updates = {};
      
      if (name != null) updates['name'] = name;
      if (address != null) updates['address'] = address;
      if (latitude != null) updates['latitude'] = latitude;
      if (longitude != null) updates['longitude'] = longitude;
      if (type != null) updates['type'] = type;

      // If coordinates changed, re-validate with OSRM
      if (latitude != null && longitude != null) {
        bool isValidated = await _validateWithOSRM(latitude, longitude);
        updates['isOsrmValidated'] = isValidated;
      }

      await collection.doc(locationId).update(updates);
      return true;
    } catch (e) {
      print('Error updating location: $e');
      return false;
    }
  }

  // Delete a saved location
  Future<bool> deleteLocation(String locationId) async {
    try {
      final collection = _savedLocationsCollection;
      if (collection == null) {
        return false;
      }

      await collection.doc(locationId).delete();
      return true;
    } catch (e) {
      print('Error deleting location: $e');
      return false;
    }
  }

  // Get a specific saved location
  Future<SavedLocation?> getLocation(String locationId) async {
    try {
      final collection = _savedLocationsCollection;
      if (collection == null) {
        return null;
      }

      final doc = await collection.doc(locationId).get();
      if (doc.exists) {
        return SavedLocation.fromMap(
          doc.data() as Map<String, dynamic>,
          doc.id,
        );
      }
      return null;
    } catch (e) {
      print('Error getting location: $e');
      return null;
    }
  }

  // Stream of saved locations for real-time updates
  Stream<List<SavedLocation>> watchSavedLocations() {
    final collection = _savedLocationsCollection;
    if (collection == null) {
      return Stream.value([]);
    }

    return collection
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return SavedLocation.fromMap(
          doc.data() as Map<String, dynamic>,
          doc.id,
        );
      }).toList();
    });
  }

  // Validate location with OSRM routing service
  Future<bool> _validateWithOSRM(double latitude, double longitude) async {
    try {
      // Use OSRM nearest service to check if location is routable
      final url = 'http://router.project-osrm.org/nearest/v1/driving/$longitude,$latitude';
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'SafeGo/1.0 (safego@example.com)'
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['code'] == 'Ok' && data['waypoints'] != null && data['waypoints'].isNotEmpty) {
          // Check if the nearest waypoint is within reasonable distance (< 1km)
          final waypoint = data['waypoints'][0];
          final nearestLocation = waypoint['location'] as List<dynamic>;
          
          if (nearestLocation.length >= 2) {
            final nearestLon = nearestLocation[0] as double;
            final nearestLat = nearestLocation[1] as double;
            
            // Calculate distance between original and nearest routable point
            final distance = _calculateDistance(latitude, longitude, nearestLat, nearestLon);
            
            // Consider valid if within 1km of a routable point
            return distance < 1.0;
          }
        }
      }
      return false;
    } catch (e) {
      print('OSRM validation error: $e');
      // If validation fails, assume valid to avoid blocking users
      return true;
    }
  }

  // Helper method to calculate distance between two points
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371.0; // Earth's radius in kilometers
    
    double lat1Rad = lat1 * math.pi / 180;
    double lat2Rad = lat2 * math.pi / 180;
    double deltaLatRad = (lat2 - lat1) * math.pi / 180;
    double deltaLonRad = (lon2 - lon1) * math.pi / 180;
    
    double a = math.sin(deltaLatRad / 2) * math.sin(deltaLatRad / 2) +
        math.cos(lat1Rad) * math.cos(lat2Rad) *
        math.sin(deltaLonRad / 2) * math.sin(deltaLonRad / 2);
    double c = 2 * math.asin(math.sqrt(a)).toDouble();
    
    return earthRadius * c;
  }

  // Check if user has any saved locations
  Future<bool> hasSavedLocations() async {
    try {
      final locations = await getSavedLocations();
      return locations.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // Get quick access locations (home and office)
  Future<Map<String, SavedLocation?>> getQuickAccessLocations() async {
    try {
      final locations = await getSavedLocations();
      
      SavedLocation? home;
      SavedLocation? office;
      
      for (final location in locations) {
        if (location.type == 'home' && home == null) {
          home = location;
        } else if (location.type == 'office' && office == null) {
          office = location;
        }
        
        // Break early if we found both
        if (home != null && office != null) break;
      }
      
      return {
        'home': home,
        'office': office,
      };
    } catch (e) {
      print('Error getting quick access locations: $e');
      return {'home': null, 'office': null};
    }
  }
}

