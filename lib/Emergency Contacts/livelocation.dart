///Dashboard page showing live location under emergency contacts dashboard///
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geocoding/geocoding.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/emergency_contact.dart';
import '../auth_service.dart';
import '../notification_service.dart';

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
  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _journeyStarted = false;
  Timer? _checkInTimer;
  int _checkInCount = 0;
  
  void _stopLiveLocationSharing() {
    // Intentionally left blank — implement platform/location cleanup here
  }
  
  void _cancelAllJourneyNotifications() {
    NotificationService.stopBackgroundMonitoring();
    debugPrint('Emergency contacts page: Stopped background notification monitoring');
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
  
  Future<void> _handleProtectedNavigation(VoidCallback navigationCallback) async {
    _showNavigationVerificationDialog(navigationCallback);
  }
  
  void _showNavigationVerificationDialog(VoidCallback navigationCallback) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _NavigationVerificationDialog(
        onAuthenticationSuccess: () async {
          Navigator.of(context).pop();
          await _stopJourneyForNavigation();
          navigationCallback();
        },
        checkInCount: _checkInCount,
      ),
    );
  }
  
  Future<void> _stopJourneyForNavigation() async {
    if (_journeyStarted) {
      setState(() {
        _journeyStarted = false;
      });
      
      _checkInTimer?.cancel();
      _stopLiveLocationSharing();
      _cancelAllJourneyNotifications();
    }
    
    final isGlobalJourneyActive = await JourneyManager.isJourneyActive();
    if (isGlobalJourneyActive) {
      await JourneyManager.requestJourneyCancellation();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Journey cancelled - Navigation authenticated successfully.'),
          backgroundColor: Colors.blue,
          duration: Duration(seconds: 3),
        ),
      );
    } else {
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
          'Live Location Tracking',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(_auth.currentUser?.uid)
            .collection('emergency_contacts')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final contacts = snapshot.data?.docs
                  .map((doc) => EmergencyContact.fromFirestore(doc as DocumentSnapshot<Map<String, dynamic>>))
                  .toList() ??
              [];

          if (contacts.isEmpty) {
            return const Center(
              child: Text(
                'No emergency contacts found',
                style: TextStyle(fontSize: 16),
              ),
            );
          }

          return ListView.builder(
            itemCount: contacts.length,
            itemBuilder: (context, index) => _buildContactTile(contacts[index]),
          );
        },
      ),
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
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lon);
      if (placemarks.isNotEmpty) {
        final placemark = placemarks.first;
        final address = [
          placemark.name,
          placemark.street,
          placemark.locality,
          placemark.administrativeArea,
          placemark.country,
        ].where((element) => element != null && element.isNotEmpty).join(', ');
        
        return address.isNotEmpty ? address : 'Current Location';
      }
    } catch (e) {
      return 'Current Location';
    }
    
    return 'Current Location';
  }

  String _calculateJourneyDuration(Timestamp? journeyStart) {
    if (journeyStart == null) return 'Unknown';
    
    final now = DateTime.now();
    final startTime = journeyStart.toDate();
    final duration = now.difference(startTime);
    
    if (duration.inDays > 0) {
      return '${duration.inDays}d ${duration.inHours % 24}h ${duration.inMinutes % 60}m';
    } else if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes % 60}m';
    } else {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.contactName != null 
              ? '${widget.contactName} — Live Journey' 
              : 'Live Journey',
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

          // Auto-fit map to show route if available
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              if (routePoints.isNotEmpty && destination != null) {
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

                minLat = math.min(minLat, destination.latitude);
                maxLat = math.max(maxLat, destination.latitude);
                minLon = math.min(minLon, destination.longitude);
                maxLon = math.max(maxLon, destination.longitude);

                final centerLat = (minLat + maxLat) / 2;
                final centerLon = (minLon + maxLon) / 2;
                final center = LatLng(centerLat, centerLon);
                
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
                    // Enhanced route visualization
                    if (routePoints.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          // Shadow for better visibility
                          Polyline(
                            points: routePoints,
                            strokeWidth: 8.0,
                            color: Colors.green.shade800,
                          ),
                          // Main route line
                          Polyline(
                            points: routePoints,
                            strokeWidth: 6.0,
                            color: Colors.green.shade400,
                          ),
                        ],
                      ),
                    // Start marker
                    if (routePoints.isNotEmpty)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: routePoints.first,
                            width: 60,
                            height: 60,
                            child: Column(
                              children: [
                                Icon(
                                  Icons.location_on,
                                  color: Colors.green.shade700,
                                  size: 30,
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade700,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'START',
                                    style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    // Destination marker
                    if (destination != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: destination,
                            width: 60,
                            height: 60,
                            child: Column(
                              children: [
                                Icon(
                                  Icons.location_on,
                                  color: Colors.red.shade600,
                                  size: 35,
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade600,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'TARGET',
                                    style: TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
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
                    // Enhanced current location marker
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: LatLng(lat, lon),
                          width: 60,
                          height: 60,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.blue.withOpacity(0.3),
                                  border: Border.all(
                                    color: Colors.blue.withOpacity(0.6),
                                    width: 2,
                                  ),
                                ),
                              ),
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.blue,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 3,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.3),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.navigation,
                                  color: Colors.white,
                                  size: 14,
                                ),
                              ),
                            ],
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
                decoration: const BoxDecoration(
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
                                'Live Journey Active',
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
                                  'Route Visible',
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
                    
                    Text(
                      '🗺️ Live Journey Tracking',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[800],
                      ),
                    ),
                    const SizedBox(height: 8),
                    
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
                                'Current Location',
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
                                    return const Row(
                                      children: [
                                        SizedBox(
                                          width: 12,
                                          height: 12,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        ),
                                        SizedBox(width: 8),
                                        Text(
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
                                  
                                  final address = addressSnapshot.data ?? 'Current Location';
                                  return Text(
                                    address,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Journey Duration',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Row(
                                children: [
                                  Icon(
                                    Icons.timer,
                                    size: 16,
                                    color: Colors.blue[600],
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _calculateJourneyDuration(ts),
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.blue[700],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Refresh button
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () {
                              setState(() {});
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('🔄 Location refreshed'),
                                  duration: Duration(seconds: 2),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            },
                            icon: const Icon(Icons.refresh, size: 20),
                            label: const Text('Refresh Location'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue[600],
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
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NavigationVerificationDialog extends StatefulWidget {
  final VoidCallback onAuthenticationSuccess;
  final int checkInCount;

  const _NavigationVerificationDialog({
    required this.onAuthenticationSuccess,
    required this.checkInCount,
  });

  @override
  _NavigationVerificationDialogState createState() => _NavigationVerificationDialogState();
}

class _NavigationVerificationDialogState extends State<_NavigationVerificationDialog> {
  Timer? _timer;
  int _secondsRemaining = 30;
  final AuthService _authService = AuthService();
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    _startAutoBiometricAuthentication();
  }

  Future<void> _startAutoBiometricAuthentication() async {
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
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication successful! Navigating...'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        
        widget.onAuthenticationSuccess();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication failed. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          _authenticateUser();
        }
      }
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
        } else {
          _timer?.cancel();
          Navigator.of(context).pop();
          
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
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
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
                  onPressed: () => Navigator.of(context).pop(),
                ),
                centerTitle: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20.0),
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
                  Text(
                    'Time remaining: ${_secondsRemaining}s',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _secondsRemaining <= 10 ? Colors.red : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      if (!_isAuthenticating)
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amber,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _authenticateUser,
                          child: const Text('Verify Now'),
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