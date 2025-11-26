///Dashboard page showing emergency contacts and live location sharing status///

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/emergency_contact.dart';
import 'emerConList.dart';
import 'myProfile.dart';
import 'homepage.dart' as home;
import 'sos.dart';
import 'auth_service.dart';
import 'notification_service.dart';

/// Global Journey Manager for cross-page communication
class JourneyManager {
  static const String _journeyActiveKey = 'safego_journey_active';
  static const String _journeyStartTimeKey = 'safego_journey_start_time';
  static const String _journeyCancelRequestKey = 'safego_journey_cancel_request';
  
  /// Set journey as active globally
  static Future<void> setJourneyActive(bool active, {DateTime? startTime}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_journeyActiveKey, active);
    if (active && startTime != null) {
      await prefs.setString(_journeyStartTimeKey, startTime.toIso8601String());
    } else if (!active) {
      await prefs.remove(_journeyStartTimeKey);
    }
  }
  
  /// Check if any journey is active globally
  static Future<bool> isJourneyActive() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_journeyActiveKey) ?? false;
  }
  
  /// Request journey cancellation globally
  static Future<void> requestJourneyCancellation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_journeyCancelRequestKey, true);
    await prefs.setString('${_journeyCancelRequestKey}_timestamp', DateTime.now().toIso8601String());
  }
  
  /// Check if journey cancellation was requested
  static Future<bool> isCancellationRequested() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_journeyCancelRequestKey) ?? false;
  }
  
  /// Clear cancellation request (called by journey page when it processes the cancellation)
  static Future<void> clearCancellationRequest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_journeyCancelRequestKey);
    await prefs.remove('${_journeyCancelRequestKey}_timestamp');
  }
  
  /// Get journey start time
  static Future<DateTime?> getJourneyStartTime() async {
    final prefs = await SharedPreferences.getInstance();
    final timeString = prefs.getString(_journeyStartTimeKey);
    if (timeString != null) {
      try {
        return DateTime.parse(timeString);
      } catch (e) {
        return null;
      }
    }
    return null;
  }
}

/// Emergency Contacts page that shows live location when user starts journey
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  int _bottomNavIndex = 2; // Track selected bottom navigation index (default to Contacts tab)
  bool _journeyStarted = false; // Tracks whether a journey is active
  Timer? _checkInTimer;
  int _checkInCount = 0;
  
  // Stub: stop live location sharing (implement actual logic as needed)
  void _stopLiveLocationSharing() {
    // Intentionally left blank — implement platform/location cleanup here
  }
  
  // Stub: cancel notifications related to an active journey
  void _cancelAllJourneyNotifications() {
    // Stop background notification monitoring (critical for preventing lingering SOS notifications)
    NotificationService.stopBackgroundMonitoring();
    debugPrint('Emergency contacts page: Stopped background notification monitoring');
  }
  
  // Stream for emergency contacts
  Stream<List<EmergencyContact>> get _emergencyContactsStream {
    final User? currentUser = _auth.currentUser;
    if (currentUser == null) {
      return Stream.value([]);
    }
    
    return _firestore
        .collection('users')
        .doc(currentUser.uid)
        .collection('emergency_contacts')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => EmergencyContact.fromFirestore(doc))
          .toList();
    });
  }

  void _viewLiveLocation(EmergencyContact contact) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EmerContactLiveView(
          ownerUid: _auth.currentUser!.uid,
          contactId: contact.id,
          contactName: contact.name,
        ),
      ),
    );
  }



  void _navigateToFullContactsList() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const EmerConList(),
      ),
    );
  }
  
  // Method to handle navigation with biometric verification (always required)
  Future<void> _handleProtectedNavigation(VoidCallback navigationCallback) async {
    // Always require biometric verification for navigation to HomePage and Profile
    // This ensures any active journey is properly cancelled before navigation
    _showNavigationVerificationDialog(navigationCallback);
  }
  
  void _showNavigationVerificationDialog(VoidCallback navigationCallback) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _NavigationVerificationDialog(
        onAuthenticationSuccess: () async {
          Navigator.of(context).pop(); // Close verification dialog
          await _stopJourneyForNavigation(); // Stop the journey when user navigates
          navigationCallback(); // Execute the original navigation
        },
        checkInCount: _checkInCount,
      ),
    );
  }
  
  Future<void> _stopJourneyForNavigation() async {
    // Stop any local journey tracking if it was active
    if (_journeyStarted) {
      setState(() {
        _journeyStarted = false;
      });
      
      _checkInTimer?.cancel();
      _stopLiveLocationSharing();
    // _exportLocationTimer removed
      
      // Cancel all pending notifications for this journey
      _cancelAllJourneyNotifications();
    }
    
    // Check if there's a global journey active and request its cancellation
    final isGlobalJourneyActive = await JourneyManager.isJourneyActive();
    if (isGlobalJourneyActive) {
      // Request global journey cancellation
      await JourneyManager.requestJourneyCancellation();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Journey cancelled - Navigation authenticated successfully.'),
          backgroundColor: Colors.blue,
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      // No journey active, just show authentication success
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Navigation authenticated successfully.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }


  Widget _buildContactTile(EmergencyContact contact) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Colors.blue[100],
              child: contact.profileImage != null
                  ? ClipOval(
                      child: Image.file(
                        contact.profileImage!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    )
                  : Icon(Icons.person, color: Colors.blue[800]),
            ),
            title: Text(
              contact.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact.phoneNumber),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      contact.allowShareLiveLocation 
                          ? Icons.location_on 
                          : Icons.location_off,
                      size: 16,
                      color: contact.allowShareLiveLocation 
                          ? Colors.green 
                          : Colors.grey,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      contact.allowShareLiveLocation 
                          ? 'Live location enabled' 
                          : 'Live location disabled',
                      style: TextStyle(
                        fontSize: 12,
                        color: contact.allowShareLiveLocation 
                            ? Colors.green[700] 
                            : Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (contact.allowShareLiveLocation) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _viewLiveLocation(contact),
                      icon: const Icon(Icons.location_on, size: 20),
                      label: const Text('View Live Location'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red[600],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),

                ],
              ),
            ),
          ] else ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, 
                       size: 16, 
                       color: Colors.orange[700]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Contact needs to enable live location sharing',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange[700],
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190),
        foregroundColor: Colors.black,
        centerTitle: true,
        title: const Text(
          'Emergency Contacts',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          // Header with instruction
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Icon(
                  Icons.location_on,
                  size: 48,
                  color: Colors.red,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Live Location Sharing',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your emergency contacts can view your live location when you start a journey.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          
          // Emergency contacts list
          Expanded(
            child: StreamBuilder<List<EmergencyContact>>(
              stream: _emergencyContactsStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Error loading contacts: ${snapshot.error}'),
                  );
                }
                
                final contacts = snapshot.data ?? [];
                
                if (contacts.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.contacts_outlined,
                          size: 80,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No emergency contacts yet',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Add contacts to share your live location during journeys',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[500],
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _navigateToFullContactsList,
                          icon: const Icon(Icons.add),
                          label: const Text('Add Contacts'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(255, 231, 155, 67),
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                
                return Column(
                  children: [
                    // Live location enabled contacts
                    if (contacts.any((c) => c.allowShareLiveLocation)) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        color: Colors.green[50],
                        child: Row(
                          children: [
                            Icon(Icons.check_circle, color: Colors.green[700]),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Live location enabled contacts (${contacts.where((c) => c.allowShareLiveLocation).length})',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green[700],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...contacts
                          .where((c) => c.allowShareLiveLocation)
                          .map((contact) => _buildContactTile(contact)),
                    ],
                    
                    // Other contacts
                    if (contacts.any((c) => !c.allowShareLiveLocation)) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        color: Colors.grey[50],
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, color: Colors.grey[600]),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Other contacts (${contacts.where((c) => !c.allowShareLiveLocation).length})',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...contacts
                          .where((c) => !c.allowShareLiveLocation)
                          .map((contact) => _buildContactTile(contact)),
                    ],
                    
                    // Manage contacts button
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _navigateToFullContactsList,
                          icon: const Icon(Icons.settings),
                          label: const Text('Manage All Contacts'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(255, 231, 155, 67),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, -1),
            ),
          ],
        ),
        child: BottomNavigationBar(
          backgroundColor: const Color.fromARGB(255, 255, 225, 190),
          selectedItemColor: Colors.black,
          unselectedItemColor: Colors.grey,
          currentIndex: _bottomNavIndex,
          onTap: (index) {
            setState(() {
              _bottomNavIndex = index;
            });
            
            if (index == 0) {
              // Navigate to HomePage with protection - requires verification to cancel journey
              _handleProtectedNavigation(() {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const home.HomePage()),
                );
              });
            } else if (index == 1) {
              // Navigate to Profile with protection - requires verification to cancel journey
              _handleProtectedNavigation(() {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const MyProfile()),
                );
              });
            }
            // index == 2 is Contacts - stays on current page (no navigation needed)
          },
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person),
              label: 'Profile',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.contacts),
              label: 'Contacts',
            ),
          ],
        ),
      ),
      floatingActionButton: SizedBox(
        width: 80,
        height: 80,
        child: FloatingActionButton(
          heroTag: 'sos_button_emergency_contacts',
          onPressed: () {
            EmergencyAlert.show(context);
          },
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(40),
            side: const BorderSide(color: Colors.red, width: 5),
          ),
          child: const Text(
            'SOS',
            style: TextStyle(
              color: Colors.black,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: _CustomSOSButtonLocation(),
    );
  }
}

/// Live location view for a specific emergency contact
class EmerContactLiveView extends StatefulWidget {
  final String ownerUid;
  final String contactId;
  final String? contactName;

  const EmerContactLiveView({
    super.key,
    required this.ownerUid,
    required this.contactId,
    this.contactName,
  });

  @override
  State<EmerContactLiveView> createState() => _EmerContactLiveViewState();
}

class _EmerContactLiveViewState extends State<EmerContactLiveView> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  MapController _mapController = MapController();

  Stream<DocumentSnapshot<Map<String, dynamic>>> get _liveDocStream {
    return _firestore
        .collection('users')
        .doc(widget.ownerUid)
        .collection('emergency_contacts')
        .doc(widget.contactId)
        .collection('live_location')
        .doc('current')
        .snapshots();
  }

  String _formatTimestamp(Timestamp? ts) {
    if (ts == null) return 'Unknown';
    final dt = ts.toDate().toLocal();
    final s = dt.toString().split('.').first;
    return s;
  }

  Future<String> _getAddressText(double lat, double lon) async {
    try {
      debugPrint('🔍 Live view geocoding for coordinates: $lat, $lon');
      
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lon);
      
      debugPrint('📋 Live view geocoding returned ${placemarks.length} placemarks');
      
      if (placemarks.isNotEmpty) {
        final placemark = placemarks.first;
        
        debugPrint('🏠 Live view placemark details:');
        debugPrint('   Street: ${placemark.street}');
        debugPrint('   SubLocality: ${placemark.subLocality}');
        debugPrint('   Locality: ${placemark.locality}');
        debugPrint('   SubAdministrativeArea: ${placemark.subAdministrativeArea}');
        debugPrint('   AdministrativeArea: ${placemark.administrativeArea}');
        debugPrint('   PostalCode: ${placemark.postalCode}');
        debugPrint('   Country: ${placemark.country}');
        debugPrint('   IsoCountryCode: ${placemark.isoCountryCode}');
        
        // Build a readable location string with comprehensive address components (identical to notification service)
        List<String> locationParts = [];
        
        // Add street number and name (avoid duplicates)
        if (placemark.street != null && placemark.street!.isNotEmpty) {
          String streetInfo = placemark.street!.trim();
          if (streetInfo.isNotEmpty && !locationParts.contains(streetInfo)) {
            locationParts.add(streetInfo);
          }
        }
        
        // Add sub-locality (neighborhood) if available (avoid duplicates)
        if (placemark.subLocality != null && placemark.subLocality!.isNotEmpty) {
          String subLocalityInfo = placemark.subLocality!.trim();
          if (subLocalityInfo.isNotEmpty && !locationParts.contains(subLocalityInfo)) {
            locationParts.add(subLocalityInfo);
          }
        }
        
        // Add locality (city/town) (avoid duplicates)
        if (placemark.locality != null && placemark.locality!.isNotEmpty) {
          String localityInfo = placemark.locality!.trim();
          if (localityInfo.isNotEmpty && !locationParts.contains(localityInfo)) {
            locationParts.add(localityInfo);
          }
        }
        
        // Add sub-administrative area (county) if no locality (avoid duplicates)
        if (placemark.subAdministrativeArea != null && placemark.subAdministrativeArea!.isNotEmpty) {
          String subAdminInfo = placemark.subAdministrativeArea!.trim();
          if (subAdminInfo.isNotEmpty && !locationParts.contains(subAdminInfo)) {
            // Only add if we don't already have locality information
            bool hasLocalityInfo = locationParts.any((part) => 
              part.toLowerCase().contains('kuala lumpur') || 
              part.toLowerCase().contains('selangor') ||
              part.toLowerCase().contains('penang'));
            if (!hasLocalityInfo) {
              locationParts.add(subAdminInfo);
            }
          }
        }
        
        // Add administrative area (state/province) (avoid duplicates)
        if (placemark.administrativeArea != null && placemark.administrativeArea!.isNotEmpty) {
          String adminInfo = placemark.administrativeArea!.trim();
          if (adminInfo.isNotEmpty && !locationParts.contains(adminInfo)) {
            locationParts.add(adminInfo);
          }
        }
        
        // Add country (avoid duplicates)
        if (placemark.country != null && placemark.country!.isNotEmpty) {
          String countryInfo = placemark.country!.trim();
          if (countryInfo.isNotEmpty && !locationParts.contains(countryInfo)) {
            locationParts.add(countryInfo);
          }
        }

        // Remove any empty parts and duplicates, then join
        locationParts = locationParts
            .where((part) => part.trim().isNotEmpty)
            .map((part) => part.trim())
            .toSet()  // Remove duplicates
            .toList();
        
        String readableLocation = locationParts.join(', ');
        if (readableLocation.isNotEmpty) {
          debugPrint('🚀 Live view geocoding success: $readableLocation');
          return readableLocation;
        }
      }
      
      debugPrint('⚠️ Live view geocoding returned no usable address parts');
      return 'Location in Malaysia';
    } catch (e) {
      debugPrint('❌ Live view geocoding error: $e');
      // Fall back to region-based location if address lookup fails
      return 'Location in Malaysia';
    }
  }

  double _calculateTotalDistance(List<LatLng> routePoints, LatLng currentLocation) {
    if (routePoints.isEmpty) return 0.0;
    
    double totalDistance = 0.0;
    LatLng? previousPoint;
    
    for (final point in routePoints) {
      if (previousPoint != null) {
        totalDistance += _distanceBetween(previousPoint.latitude, previousPoint.longitude, point.latitude, point.longitude);
      }
      previousPoint = point;
    }
    
    return totalDistance / 1000; // Convert to kilometers
  }

  double _distanceBetween(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadius = 6371000; // Earth's radius in meters
    final double dLat = _degreesToRadians(lat2 - lat1);
    final double dLon = _degreesToRadians(lon2 - lon1);
    
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degreesToRadians(lat1)) * math.cos(_degreesToRadians(lat2)) *
        math.sin(dLon / 2) * math.sin(dLon / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    
    return earthRadius * c;
  }

  double _degreesToRadians(double degrees) {
    return degrees * (math.pi / 180);
  }

  String _calculateEstimatedArrival(double currentLat, double currentLon, LatLng? destination) {
    if (destination == null) {
      return 'No destination set';
    }
    
    // Calculate distance to destination in meters
    final double distanceToDestination = _distanceBetween(
      currentLat, currentLon, 
      destination.latitude, destination.longitude
    );
    
    // Convert to kilometers
    final double distanceKm = distanceToDestination / 1000;
    
    // Estimate travel time based on average speeds
    // Assume different speeds based on distance (walking/driving)
    double estimatedMinutes;
    
    if (distanceKm < 2.0) {
      // Walking speed for short distances (5 km/h)
      estimatedMinutes = (distanceKm / 5.0) * 60;
    } else if (distanceKm < 10.0) {
      // City driving/public transport (25 km/h average)
      estimatedMinutes = (distanceKm / 25.0) * 60;
    } else {
      // Highway/faster travel (50 km/h average)
      estimatedMinutes = (distanceKm / 50.0) * 60;
    }
    
    // Format the estimated time
    if (estimatedMinutes < 1) {
      return 'Arriving soon';
    } else if (estimatedMinutes < 60) {
      return '${estimatedMinutes.round()} min';
    } else {
      final hours = (estimatedMinutes / 60).floor();
      final remainingMinutes = (estimatedMinutes % 60).round();
      if (remainingMinutes == 0) {
        return '~${hours}h to arrive';
      } else {
        return '~${hours}h ${remainingMinutes}m to arrive';
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.contactName != null 
              ? '${widget.contactName} — Live' 
              : 'Live Location',
        ),
        backgroundColor: const Color.fromARGB(255, 255, 225, 190),
        foregroundColor: Colors.black,
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _liveDocStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final doc = snapshot.data;
          if (doc == null || !doc.exists || doc.data() == null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.location_off, size: 80, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'No live location available',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Location will appear when ${widget.contactName ?? 'the user'} starts a journey',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () {
                      // Trigger a manual refresh
                      setState(() {});
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check Again'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue[600],
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            );
          }

          final data = doc.data()!;
          final lat = (data['latitude'] as num?)?.toDouble();
          final lon = (data['longitude'] as num?)?.toDouble();
          final accuracy = (data['accuracy'] as num?)?.toDouble();
          final ts = data['timestamp'] is Timestamp ? data['timestamp'] as Timestamp : null;
          final hasRoute = data['hasRoute'] as bool? ?? false;
          final routePointsData = data['routePoints'] as List<dynamic>?;
          final destinationData = data['destination'] as Map<String, dynamic>?;

          if (lat == null || lon == null) {
            return const Center(child: Text('Live location data incomplete'));
          }

          // Parse route points if available
          List<LatLng> routePoints = [];
          LatLng? destination;
          
          if (hasRoute && routePointsData != null) {
            routePoints = routePointsData
                .map((point) {
                  final pointMap = point as Map<String, dynamic>;
                  final pointLat = (pointMap['lat'] as num?)?.toDouble();
                  final pointLon = (pointMap['lng'] as num?)?.toDouble();
                  if (pointLat != null && pointLon != null) {
                    return LatLng(pointLat, pointLon);
                  }
                  return null;
                })
                .where((point) => point != null)
                .cast<LatLng>()
                .toList();
          }

          if (destinationData != null) {
            final destLat = (destinationData['lat'] as num?)?.toDouble();
            final destLon = (destinationData['lng'] as num?)?.toDouble();
            if (destLat != null && destLon != null) {
              destination = LatLng(destLat, destLon);
            }
          }

          // Auto-fit map to show route if available, otherwise center on current location
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              if (routePoints.isNotEmpty) {
                // Calculate bounds to fit the entire route
                double minLat = lat;
                double maxLat = lat;
                double minLon = lon;
                double maxLon = lon;

                for (final point in routePoints) {
                  minLat = math.min(minLat, point.latitude);
                  maxLat = math.max(maxLat, point.latitude);
                  minLon = math.min(minLon, point.longitude);
                  maxLon = math.max(maxLon, point.longitude);
                }

                if (destination != null) {
                  minLat = math.min(minLat, destination.latitude);
                  maxLat = math.max(maxLat, destination.latitude);
                  minLon = math.min(minLon, destination.longitude);
                  maxLon = math.max(maxLon, destination.longitude);
                }

                // Calculate center and zoom to fit the route
                final centerLat = (minLat + maxLat) / 2;
                final centerLon = (minLon + maxLon) / 2;
                final center = LatLng(centerLat, centerLon);
                
                // Calculate appropriate zoom level based on bounds
                final latDiff = maxLat - minLat;
                final lonDiff = maxLon - minLon;
                final maxDiff = math.max(latDiff, lonDiff);
                
                double zoom = 16.0;
                if (maxDiff > 0.1) zoom = 10.0;
                else if (maxDiff > 0.05) zoom = 12.0;
                else if (maxDiff > 0.01) zoom = 14.0;

                _mapController.move(center, zoom);
              } else {
                _mapController.move(LatLng(lat, lon), 16.0);
              }
            } catch (_) {}
          });

          return Column(
            children: [
              Expanded(
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: LatLng(lat, lon),
                    initialZoom: 16.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.safego',
                    ),
                    // Route line layer (if route is available)
                    if (routePoints.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: routePoints,
                            strokeWidth: 4.0,
                            color: Colors.blue,
                          ),
                        ],
                      ),
                    // Destination marker (if available)
                    if (destination != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: destination,
                            width: 60,
                            height: 60,
                            child: const Icon(
                              Icons.flag,
                              color: Colors.green,
                              size: 30,
                            ),
                          ),
                        ],
                      ),
                    // Current location accuracy circle
                    CircleLayer(
                      circles: [
                        CircleMarker(
                          point: LatLng(lat, lon),
                          color: Colors.blue.withOpacity(0.2),
                          borderColor: Colors.blue.withOpacity(0.5),
                          radius: accuracy != null ? math.max(accuracy / 2, 10) : 15,
                          borderStrokeWidth: 2,
                        ),
                      ],
                    ),
                    // Current location marker
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: LatLng(lat, lon),
                          width: 80,
                          height: 80,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.person,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(color: Colors.black12, blurRadius: 6),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Status indicators
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.green[100],
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.green[300]!),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.circle, color: Colors.green[600], size: 8),
                              const SizedBox(width: 6),
                              Text(
                                'Live Location Active',
                                style: TextStyle(
                                  color: Colors.green[700],
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (hasRoute) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.blue[100],
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.blue[300]!),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.route, color: Colors.blue[600], size: 12),
                                const SizedBox(width: 6),
                                Text(
                                  'Journey Route',
                                  style: TextStyle(
                                    color: Colors.blue[700],
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    // Location details
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Last updated',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                _formatTimestamp(ts),
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Location',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              FutureBuilder<String>(
                                future: _getAddressText(lat, lon),
                                builder: (context, addressSnapshot) {
                                  if (addressSnapshot.connectionState == ConnectionState.waiting) {
                                    return Row(
                                      children: [
                                        SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Colors.blue[600]!),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Text(
                                          'Getting location...',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontStyle: FontStyle.italic,
                                            color: Colors.grey,
                                          ),
                                        ),
                                      ],
                                    );
                                  }
                                  
                                  final address = addressSnapshot.data ?? 'Location in Malaysia';
                                  return Text(
                                    address,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  );
                                },
                              ),
                              // Journey time display
                              const SizedBox(height: 8),
                              Text(
                                'Estimated Arrival',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Row(
                                children: [
                                  Icon(
                                    Icons.access_time,
                                    size: 16,
                                    color: Colors.blue[600],
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _calculateEstimatedArrival(lat, lon, destination),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.blue[700],
                                    ),
                                  ),
                                ],
                              ),
                              if (hasRoute) ...[
                                const SizedBox(height: 8),
                                Text(
                                  'Journey Distance',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Row(
                                  children: [
                                    Icon(Icons.straighten, size: 16, color: Colors.green[600]),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${_calculateTotalDistance(routePoints, LatLng(lat, lon)).toStringAsFixed(1)} km',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.green[700],
                                      ),
                                    ),
                                    if (destination != null) ...[
                                      const SizedBox(width: 12),
                                      Icon(Icons.flag, size: 16, color: Colors.orange[600]),
                                      Text(
                                        'To destination',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.orange[700],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    

                    
                    const SizedBox(height: 8),
                    
                    // Refresh button
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          try {
                            final fresh = await _firestore
                                .collection('users')
                                .doc(widget.ownerUid)
                                .collection('emergency_contacts')
                                .doc(widget.contactId)
                                .collection('live_location')
                                .doc('current')
                                .get();
                            if (fresh.exists && fresh.data() != null) {
                              final f = fresh.data()!;
                              final fLat = (f['latitude'] as num?)?.toDouble();
                              final fLon = (f['longitude'] as num?)?.toDouble();
                              if (fLat != null && fLon != null) {
                                _mapController.move(LatLng(fLat, fLon), 16.0);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Location updated'),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              }
                            }
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Refresh failed: $e'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.refresh, size: 20),
                        label: const Text('Refresh Location'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.grey[700],
                          side: BorderSide(color: Colors.grey[400]!),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            builder: (context) => Container(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Quick Actions',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[800],
                    ),
                  ),
                  const SizedBox(height: 20),
                  ListTile(
                    leading: const Icon(Icons.phone, color: Colors.green),
                    title: const Text('Call Emergency Contact'),
                    onTap: () {
                      Navigator.pop(context);
                      // Here you could implement calling functionality
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Calling ${widget.contactName}...'),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.message, color: Colors.blue),
                    title: const Text('Send Message'),
                    onTap: () {
                      Navigator.pop(context);
                      // Here you could implement messaging functionality
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Opening message to ${widget.contactName}...'),
                          backgroundColor: Colors.blue,
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.share, color: Colors.orange),
                    title: const Text('Share Location'),
                    onTap: () {
                      Navigator.pop(context);
                      // Here you could implement location sharing
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Location shared!'),
                          backgroundColor: Colors.orange,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
        backgroundColor: Colors.red[600],
        child: const Icon(Icons.emergency, color: Colors.white),
      ),
    );
  }
}

/// Simple singleton notifier that other parts of the app can use to notify
/// the Emergency Contacts UI about added contacts. It exposes a broadcast
/// stream and a convenience `addContact` method.
class ContactNotifier {
  ContactNotifier._internal();

  static final ContactNotifier instance = ContactNotifier._internal();

  final StreamController<String> _controller = StreamController<String>.broadcast();

  Stream<String> get onContactAdded => _controller.stream;

  void addContact(String name) {
    try {
      _controller.add(name);
    } catch (_) {}
  }

  void dispose() {
    _controller.close();
  }
}

// Custom FloatingActionButtonLocation to position SOS button directly above navigation bar
class _CustomSOSButtonLocation extends FloatingActionButtonLocation {
  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    // Get the center x position
    final double fabX = (scaffoldGeometry.scaffoldSize.width - scaffoldGeometry.floatingActionButtonSize.width) / 2;
    
    // Position the button to float on top of the bottom navigation bar
    final double fabY = scaffoldGeometry.scaffoldSize.height - 
                        56.0 - // Standard bottom navigation bar height
                        (scaffoldGeometry.floatingActionButtonSize.height / 2); // Half the button height to center it on nav bar
    
    return Offset(fabX, fabY);
  }
}

// Navigation verification dialog widget for protecting navigation during journey
class _NavigationVerificationDialog extends StatefulWidget {
  final Future<void> Function() onAuthenticationSuccess;
  final int? checkInCount;

  const _NavigationVerificationDialog({
    required this.onAuthenticationSuccess,
    this.checkInCount,
  });

  @override
  _NavigationVerificationDialogState createState() => _NavigationVerificationDialogState();
}

class _NavigationVerificationDialogState extends State<_NavigationVerificationDialog> {
  Timer? _timer;
  int _secondsRemaining = 30; // 30 second countdown
  final AuthService _authService = AuthService();
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    _startAutoBiometricAuthentication();
  }

  Future<void> _startAutoBiometricAuthentication() async {
    // Start biometric authentication automatically after a brief delay
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      _authenticateUser();
    }
  }

  Future<void> _authenticateUser() async {
    if (_isAuthenticating) return;
    
    setState(() {
      _isAuthenticating = true;
    });

    bool isAuthenticated = await _authService.authenticateWithBiometrics();
    
    if (mounted) {
      setState(() {
        _isAuthenticating = false;
      });

      if (isAuthenticated) {
        _timer?.cancel();
        
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication successful! Navigating...'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        
        // Call the success callback to allow navigation (await for journey cancellation)
        await widget.onAuthenticationSuccess();
      } else {
        // Authentication failed - show retry message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication failed. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        // Retry authentication after a delay
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          _authenticateUser(); // Retry authentication
        }
      }
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
        } else {
          _timer?.cancel();
          // Auto-close dialog when timer reaches 0 without allowing navigation
          Navigator.of(context).pop(); // Close dialog but block navigation
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Navigation verification timeout. Please try again to navigate.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent back button from closing without authentication
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          // Don't allow navigation, just close dialog
          Navigator.of(context).pop();
        }
      },
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Custom AppBar for the popup
            Container(
              decoration: const BoxDecoration(
                color: Color.fromARGB(255, 255, 193, 7),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                title: const Text(
                  'Verify Navigation',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.black),
                  onPressed: () => Navigator.of(context).pop(), // Close dialog but block navigation
                ),
                centerTitle: true,
              ),
            ),
            
            // Content section
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: [
                  const Icon(
                    Icons.security,
                    color: Colors.amber,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Please verify your identity to navigate during an active journey.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.black),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Active check-ins completed: ${widget.checkInCount}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  // Biometrics images
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.amber.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.amber.withOpacity(0.3),
                                width: 2,
                              ),
                            ),
                            child: Image.asset(
                              'assets/face.png',
                              width: 80,
                              height: 80,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isAuthenticating ? 'Authenticating...' : 'Tap to verify',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.amber.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 32),
                      Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.amber.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.amber.withOpacity(0.3),
                                width: 2,
                              ),
                            ),
                            child: Image.asset(
                              'assets/fingerprint.png',
                              width: 80,
                              height: 80,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isAuthenticating ? 'Authenticating...' : 'Tap to verify',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.amber.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Timer display
                  Column(
                    children: [
                      Text(
                        'Time remaining to verify navigation:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Minutes container
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color.fromARGB(255, 206, 206, 206),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color.fromARGB(255, 122, 122, 122).withValues(alpha: 0.3),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Text(
                                  (_secondsRemaining ~/ 60).toString().padLeft(2, '0'),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                                const Text(
                                  'Minutes',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Colon separator
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              ':',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                          ),
                          // Seconds container
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color.fromARGB(255, 206, 206, 206),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color.fromARGB(255, 122, 122, 122).withValues(alpha: 0.3),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Text(
                                  (_secondsRemaining % 60).toString().padLeft(2, '0'),
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: _secondsRemaining <= 10 ? Colors.red : Colors.black,
                                  ),
                                ),
                                const Text(
                                  'Seconds',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Manual verify button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Cancel button
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        ),
                        onPressed: () => Navigator.of(context).pop(), // Close dialog but block navigation
                        child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      // Verify button
                      if (!_isAuthenticating)
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          ),
                          onPressed: _authenticateUser,
                          child: const Text('Verify Now', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Exit verification dialog widget for journey cancellation
class _ExitVerificationDialog extends StatefulWidget {
  final VoidCallback onAuthenticationSuccess;
  final int checkInCount;

  const _ExitVerificationDialog({
    required this.onAuthenticationSuccess,
    required this.checkInCount,
  });

  @override
  _ExitVerificationDialogState createState() => _ExitVerificationDialogState();
}

class _ExitVerificationDialogState extends State<_ExitVerificationDialog> {
  Timer? _timer;
  int _secondsRemaining = 30; // 30 second countdown
  final AuthService _authService = AuthService();
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    _startAutoBiometricAuthentication();
  }

  Future<void> _startAutoBiometricAuthentication() async {
    // Start biometric authentication automatically after a brief delay
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      _authenticateUser();
    }
  }

  Future<void> _authenticateUser() async {
    if (_isAuthenticating) return;
    
    setState(() {
      _isAuthenticating = true;
    });

    bool isAuthenticated = await _authService.authenticateWithBiometrics();
    
    if (mounted) {
      setState(() {
        _isAuthenticating = false;
      });

      if (isAuthenticated) {
        _timer?.cancel();
        
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication successful! Exiting journey...'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        
        // Call the success callback to exit journey
        widget.onAuthenticationSuccess();
      } else {
        // Authentication failed - show retry message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication failed. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        // Retry authentication after a delay
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          _authenticateUser(); // Retry authentication
        }
      }
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
        } else {
          _timer?.cancel();
          // Auto-close dialog when timer reaches 0 without exiting journey
          Navigator.of(context).pop(); // Close dialog but stay in journey
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Exit verification timeout. Journey continues for your safety.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent back button from closing without authentication
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          // Don't exit journey, just close dialog
          Navigator.of(context).pop();
        }
      },
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Custom AppBar for the popup
            Container(
              decoration: const BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                title: const Text(
                  'Exit Journey',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(), // Close dialog but stay in journey
                ),
                centerTitle: true,
              ),
            ),
            // Content section
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: [
                  const Icon(
                    Icons.warning,
                    color: Colors.red,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Are you sure you want to exit?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your journey is still active. Exiting will stop safety tracking.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Active check-ins completed: ${widget.checkInCount}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  // Biometrics images
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.red.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.red.withOpacity(0.3),
                                width: 2,
                              ),
                            ),
                            child: Image.asset(
                              'assets/face.png',
                              width: 80,
                              height: 80,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isAuthenticating ? 'Authenticating...' : 'Tap to verify',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.red,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 32),
                      Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.red.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.red.withOpacity(0.3),
                                width: 2,
                              ),
                            ),
                            child: Image.asset(
                              'assets/fingerprint.png',
                              width: 80,
                              height: 80,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isAuthenticating ? 'Authenticating...' : 'Tap to verify',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.red,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Timer display
                  Column(
                    children: [
                      Text(
                        'Time remaining to verify exit:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Minutes container
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color.fromARGB(255, 206, 206, 206),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color.fromARGB(255, 122, 122, 122).withValues(alpha: 0.3),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Text(
                                  (_secondsRemaining ~/ 60).toString().padLeft(2, '0'),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                                const Text(
                                  'Minutes',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Colon separator
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              ':',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                          ),
                          // Seconds container
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color.fromARGB(255, 206, 206, 206),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color.fromARGB(255, 122, 122, 122).withValues(alpha: 0.3),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Text(
                                  (_secondsRemaining % 60).toString().padLeft(2, '0'),
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: _secondsRemaining <= 10 ? Colors.red : Colors.black,
                                  ),
                                ),
                                const Text(
                                  'Seconds',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Manual verify button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Cancel button
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        ),
                        onPressed: () => Navigator.of(context).pop(), // Close dialog but stay in journey
                        child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      // Verify button
                      if (!_isAuthenticating)
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          ),
                          onPressed: _authenticateUser,
                          child: const Text('Verify Exit', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Authentication dialog widget for arrival verification
class _ArrivalAuthenticationDialog extends StatefulWidget {
  final VoidCallback onAuthenticationSuccess;
  final int checkInCount;

  const _ArrivalAuthenticationDialog({
    required this.onAuthenticationSuccess,
    required this.checkInCount,
  });

  @override
  _ArrivalAuthenticationDialogState createState() => _ArrivalAuthenticationDialogState();
}

class _ArrivalAuthenticationDialogState extends State<_ArrivalAuthenticationDialog> {
  Timer? _timer;
  int _secondsRemaining = 30; // 30 second countdown
  final AuthService _authService = AuthService();
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    _startAutoBiometricAuthentication();
  }

  Future<void> _startAutoBiometricAuthentication() async {
    // Start biometric authentication automatically after a brief delay
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      _authenticateUser();
    }
  }

  Future<void> _authenticateUser() async {
    if (_isAuthenticating) return;
    
    setState(() {
      _isAuthenticating = true;
    });

    bool isAuthenticated = await _authService.authenticateWithBiometrics();
    
    if (mounted) {
      setState(() {
        _isAuthenticating = false;
      });

      if (isAuthenticated) {
        _timer?.cancel();
        Navigator.of(context).pop(); // Close authentication dialog
        
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication successful! Confirming arrival...'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        
        // Call the success callback to show "I'm Safe" dialog
        widget.onAuthenticationSuccess();
      } else {
        // Authentication failed - show retry message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication failed. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        // Retry authentication after a delay
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          _authenticateUser(); // Retry authentication
        }
      }
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
        } else {
          _timer?.cancel();
          // Auto-fail authentication when timer reaches 0
          Navigator.of(context).pop(); // Close dialog
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Authentication timeout. Please try again.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent back button from closing without authentication
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _authenticateUser();
        }
      },
      child: Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Custom AppBar for the popup
            Container(
              decoration: const BoxDecoration(
                color: Color.fromARGB(255, 250, 198, 138),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                title: const Text(
                  'Verify Arrival',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _authenticateUser,
                ),
                centerTitle: true,
              ),
            ),
            // Content section
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: [
                  const Text(
                    'Verify your identity to confirm safe arrival',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  // Biometrics images
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.blue.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.blue.withOpacity(0.3),
                                width: 2,
                              ),
                            ),
                            child: Image.asset(
                              'assets/face.png',
                              width: 100,
                              height: 100,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isAuthenticating ? 'Auto authenticating...' : 'Auto authenticating...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 32),
                      Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: Colors.blue.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.blue.withOpacity(0.3),
                                width: 2,
                              ),
                            ),
                            child: Image.asset(
                              'assets/fingerprint.png',
                              width: 100,
                              height: 100,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _isAuthenticating ? 'Auto authenticating...' : 'Auto authenticating...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Timer display
                  Column(
                    children: [
                      Text(
                        'Time remaining to verify arrival:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Minutes container
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color.fromARGB(255, 206, 206, 206),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color.fromARGB(255, 122, 122, 122).withValues(alpha: 0.3),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Text(
                                  (_secondsRemaining ~/ 60).toString().padLeft(2, '0'),
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                                const Text(
                                  'Minutes',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Colon separator
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              ':',
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                          ),
                          // Seconds container
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color.fromARGB(255, 206, 206, 206),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color.fromARGB(255, 122, 122, 122).withValues(alpha: 0.3),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Text(
                                  (_secondsRemaining % 60).toString().padLeft(2, '0'),
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: _secondsRemaining <= 10 ? Colors.red : Colors.black,
                                  ),
                                ),
                                const Text(
                                  'Seconds',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Manual retry button
                  if (!_isAuthenticating)
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                      ),
                      onPressed: _authenticateUser,
                      child: const Text('Verify Now', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
