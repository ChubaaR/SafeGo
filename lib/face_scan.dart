// lib/Journey.dart
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:safego/Journey.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'auth_service.dart';
import 'notification_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:safego/myProfile.dart';
import 'package:safego/homepage.dart';
import 'package:safego/sos.dart' as sos;
import 'package:safego/widgets/profile_avatar.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class FaceScan extends StatefulWidget {
  final String destination;
  final LatLng? currentLocation;
  final String currentAddress;
  final LatLng? destinationCoords; 
  final String transportMode; 

  const FaceScan({
    super.key,
    required this.destination,
    this.currentLocation,
    required this.currentAddress,
    this.destinationCoords, // Optional destination coordinates
    this.transportMode = 'driving', // Default to driving
  });

  @override
  FaceScanState createState() => FaceScanState();
}

class FaceScanState extends State<FaceScan> {
  final MapController mapController = MapController();
  final TextEditingController destinationController = TextEditingController();
  final AuthService _authService = AuthService();
  
  LatLng? currentLocation;
  LatLng? destinationLocation;
  bool isLoading = false;
  String currentAddress = "Unknown";
  
  // Route variables
  List<LatLng> routePoints = [];
  bool showRoute = false;
  String? routeDistance;
  String? routeDuration;


  void _enablebiometrics() async {
    bool success = await _authService.authenticateWithBiometrics();
    if (success) {


      // Send an in-app/local notification announcing journey start
      try {
        final user = FirebaseAuth.instance.currentUser;
        final userName = user?.displayName ?? user?.email ?? 'User';
        final now = DateTime.now();
        final startTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
        
        // Get current location for the notification
        String? locationString;
        if (currentLocation != null) {
          locationString = '${currentLocation!.latitude.toStringAsFixed(6)}, ${currentLocation!.longitude.toStringAsFixed(6)}';
        }

        // Send notification to emergency contacts (both local and FCM)
        await NotificationService.showJourneyStartedNotification(
          userName: userName,
          destination: widget.destination,
          startTime: startTime,
          currentLocation: locationString,
        );
        
        // Debug FCM test popup removed - notifications now send automatically via FCM connections
        
        // Write journey started info to file for emergency contacts to detect
        await _writeJourneyStartedFile(userName, widget.destination, startTime);
        
        // Also send to Firebase for cross-device communication
        await _sendJourneyStartedToFirebase(userName, widget.destination, startTime);
        
        debugPrint('Journey started notification sent for $userName to ${widget.destination} at $startTime');
      } catch (e) {
        debugPrint('Failed to send journey started notification: $e');
      }

      // Navigate to HomePage on successful authentication
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => Journey(
            destination: widget.destination,
            currentLocation: currentLocation,
            currentAddress: currentAddress,
            destinationCoords: widget.destinationCoords,
            transportMode: widget.transportMode,
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authentication failed')),
      );
    }
  }
  

  @override
  void initState() {
    super.initState();
    // Initialize with passed data
    currentLocation = widget.currentLocation;
    currentAddress = widget.currentAddress;
    destinationController.text = widget.destination;

    _getCurrentLocation(); // Get current location

    // If destination coordinates are provided, use them directly
    if (widget.destinationCoords != null) {
      destinationLocation = widget.destinationCoords;
      // Automatically show route when destination coordinates are available
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showRoute();
      });
    } else {
      // Otherwise, geocode the destination address
      _handleDestinationInput(widget.destination);
    }
  }

  // Write journey started information to file for emergency contacts to detect
  Future<void> _writeJourneyStartedFile(String userName, String destination, String startTime) async {
    try {
      final Map<String, dynamic> journeyData = {
        'userName': userName,
        'destination': destination,
        'startTime': startTime,
        'timestamp': DateTime.now().toIso8601String(),
      };

      // Try primary workspace path first
      const primaryPath = r'C:\Users\chuba\Desktop\safego\safego\.journey_started.json';
      final primaryFile = File(primaryPath);
      
      try {
        await primaryFile.writeAsString(json.encode(journeyData));
        debugPrint('Journey started file written to primary path: $primaryPath');
      } catch (e) {
        // If primary path fails, try fallback
        final localApp = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['HOME'] ?? '.';
        final fallbackPath = '$localApp${Platform.pathSeparator}safego${Platform.pathSeparator}.journey_started.json';
        final fallbackDir = Directory('$localApp${Platform.pathSeparator}safego');
        
        // Create directory if it doesn't exist
        if (!await fallbackDir.exists()) {
          await fallbackDir.create(recursive: true);
        }
        
        final fallbackFile = File(fallbackPath);
        await fallbackFile.writeAsString(json.encode(journeyData));
        debugPrint('Journey started file written to fallback path: $fallbackPath');
      }
    } catch (e) {
      debugPrint('Failed to write journey started file: $e');
    }
  }

  // Send journey started information to Firebase for cross-device communication (FCM token-based)
  Future<void> _sendJourneyStartedToFirebase(String userName, String destination, String startTime) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('No authenticated user for Firebase journey notification');
        return;
      }

      // Get current location for the notification
      String currentLocation = 'Location not available';
      if (widget.currentLocation != null) {
        try {
          final address = await getAddressFromCoordinates(
            widget.currentLocation!.latitude,
            widget.currentLocation!.longitude,
          );
          currentLocation = address;
        } catch (e) {
          currentLocation = '${widget.currentLocation!.latitude.toStringAsFixed(6)}, ${widget.currentLocation!.longitude.toStringAsFixed(6)}';
        }
      }

      // Send customized journey FCM notifications (similar to SOS flow)
      debugPrint('📤 Sending customized journey FCM notifications from user: ${user.uid}');
      
      // Get connected FCM devices (manual device pairing)
      final connectionsSnapshot = await FirebaseFirestore.instance
          .collection('fcm_connections')
          .where('userIdA', isEqualTo: user.uid)
          .get();

      debugPrint('📊 Found ${connectionsSnapshot.docs.length} connected devices for journey notifications');

      // Send FCM notification to each connected device using their FCM token
      for (final connectionDoc in connectionsSnapshot.docs) {
        final connectionData = connectionDoc.data();
        final deviceBToken = connectionData['tokenB'] as String?;
        
        if (deviceBToken != null) {
          // Create Firestore notification targeting Device B's FCM token
          await FirebaseFirestore.instance
              .collection('journey_notifications')
              .add({
            'type': 'journey_started',
            'fromUserId': user.uid,
            'fromUserName': userName,
            'targetToken': deviceBToken, 
            'title': '🚗 Journey Started',
            'userName': userName,
            'destination': widget.destination, 
            'startTime': startTime,
            'fromLocation': currentLocation,
            'displayFormat': 'emergency_page', 
            'body': '$userName started journey to ${widget.destination} at $startTime. Tap to view live location and track progress',
            'timestamp': FieldValue.serverTimestamp(),
            'read': false,
            'priority': 'normal',
            'isEmergency': false,
            'notificationType': 'journey_notification',
            'journeyId': '${user.uid}_${DateTime.now().millisecondsSinceEpoch}',
            'deviceAUserId': user.uid,
            'createdAt': FieldValue.serverTimestamp(),
          });
          
          // Also send direct FCM notification to Device B
          await _sendDirectFCMNotification(
            token: deviceBToken,
            title: '🚗 Journey Started',
            body: '$userName started journey to $destination at $startTime.\n📍 Tap to view live location and track progress',
            data: {
              'type': 'journey_started',
              'fromUserId': user.uid,
              'fromUserName': userName,
              'destination': destination,
              'startTime': startTime,
              'fromLocation': currentLocation,
              'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            },
          );
          
          debugPrint('📤 Journey notification sent to Device B via FCM token: ${deviceBToken.substring(0, 20)}...');
        }
      }

      // Also notify emergency contacts using FCM tokens
      debugPrint('📊 Found ${connectionsSnapshot.docs.length} connected devices for journey notifications');
      
      final contactsSnapshot = await FirebaseFirestore.instance
          .collection('emergency_contacts')
          .where('userId', isEqualTo: user.uid)
          .get();

      debugPrint('📊 Found ${contactsSnapshot.docs.length} emergency contacts');

      // Send FCM notification to emergency contacts who have the app
      for (final contactDoc in contactsSnapshot.docs) {
        final contactData = contactDoc.data();
        final emergencyContactId = contactData['emergencyContactId'] as String?;
        
        if (emergencyContactId != null) {
          // Get the emergency contact's FCM token
          final fcmTokensSnapshot = await FirebaseFirestore.instance
              .collection('fcm_tokens')
              .where('userId', isEqualTo: emergencyContactId)
              .limit(1)
              .get();
          
          if (fcmTokensSnapshot.docs.isNotEmpty) {
            final tokenDoc = fcmTokensSnapshot.docs.first;
            final fcmToken = tokenDoc.data()['token'] as String?;
            
            if (fcmToken != null) {
              // Send FCM-based journey notification to emergency contact
              await FirebaseFirestore.instance
                  .collection('journey_notifications')
                  .add({
                'type': 'journey_started',
                'fromUserId': user.uid,
                'fromUserName': userName,
                'targetToken': fcmToken, // FCM token-based targeting
                'title': '🚗 Journey Started',
                'userName': userName,
                'destination': destination,
                'startTime': startTime,
                'fromLocation': currentLocation,
                'displayFormat': 'emergency_page', // This will trigger Device B listeners
                'timestamp': FieldValue.serverTimestamp(),
                'read': false,
                'priority': 'normal',
                'isEmergency': false,
                'notificationType': 'journey_notification',
                'journeyId': '${user.uid}_${DateTime.now().millisecondsSinceEpoch}',
                'createdAt': FieldValue.serverTimestamp(),
              });
              
              debugPrint('Journey FCM notification queued for ${contactData['name']} ($emergencyContactId)');
            }
          }
        }
      }
      
      debugPrint('Journey started FCM notifications sent to all emergency contacts with the app');
    } catch (e) {
      debugPrint('Failed to send journey started notification to Firebase: $e');
    }
  }



  // Rate limiting for Nominatim API
  static DateTime? _lastNominatimRequest;
  static const _nominatimDelay = Duration(seconds: 1);

  // Method to convert address to coordinates (geocoding)
  Future<LatLng?> geocodeAddress(String address) async {
    // Validate input
    if (address.trim().isEmpty) {
      debugPrint('Empty address provided for geocoding');
      return null;
    }
    
    // Rate limiting: ensure at least 1 second between requests
    if (_lastNominatimRequest != null) {
      final timeSinceLastRequest = DateTime.now().difference(_lastNominatimRequest!);
      if (timeSinceLastRequest < _nominatimDelay) {
        await Future.delayed(_nominatimDelay - timeSinceLastRequest);
      }
    }
    _lastNominatimRequest = DateTime.now();
    final url =
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(address)}&format=json&limit=1';

    final response = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'SafeGoApp/1.0 (contact@safego.app)',
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://safego.app'
      },
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data.isNotEmpty) {
        try {
          final lat = double.parse(data[0]['lat']);
          final lon = double.parse(data[0]['lon']);
          
          // Validate parsed coordinates
          if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
            debugPrint('Invalid coordinates from API: lat=$lat, lon=$lon');
            return null;
          }
          
          return LatLng(lat, lon);
        } catch (e) {
          debugPrint('Error parsing coordinates from API: $e');
          return null;
        }
      }
    } else if (response.statusCode == 403) {
      debugPrint('Nominatim geocoding API access forbidden (403). Please try again later.');
    } else {
      debugPrint('Geocoding failed with status: ${response.statusCode}. Please try again later.');
    }
    return null;
  }

  // Show route
  Future<void> _showRoute() async {
    if (currentLocation == null || destinationLocation == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please wait for current location and enter destination')),
        );
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      isLoading = true;
    });

    try {
      await _getRouteFromOSRM();
    } catch (e) {
      debugPrint('Route retrieval error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to get route')),
        );
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // Method to get route from OSRM
  Future<void> _getRouteFromOSRM() async {
    if (currentLocation == null || destinationLocation == null) return;

    // Configuration: Try local OSRM server first, fallback to public server
    const bool useLocalServer = false; // Set to true if you have local OSRM Docker container running
    final String baseUrl = useLocalServer 
        // ignore: dead_code
        ? 'http://localhost:5000/route/v1'
        : 'https://router.project-osrm.org/route/v1';
    // Use the transport mode passed from homepage
    String profile = widget.transportMode;
    
    // Map our transport modes to OSRM profiles
    switch (widget.transportMode) {
      case 'driving':
        profile = 'driving';
        break;
      case 'walking':
        profile = 'driving'; // Use driving profile but adjust calculations for walking
        break;
      case 'transit':
        // OSRM doesn't have transit, goback to driving but we'll adjust time later
        profile = 'driving';
        break;
      default:
        profile = 'driving';
    }

    final String coordinates =
        '${currentLocation!.longitude},${currentLocation!.latitude};${destinationLocation!.longitude},${destinationLocation!.latitude}';

    final String options = 'overview=full&geometries=geojson';
    final String url = '$baseUrl/$profile/$coordinates?$options';

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['code'] == 'Ok') {
          final route = data['routes'][0];
          final geometry = route['geometry'];
          final coords = geometry['coordinates'] as List;

          final distance = route['distance'] as num;
          final duration = route['duration'] as num;

          List<LatLng> points = coords.map<LatLng>((coord) {
            final double lng = (coord[0] as num).toDouble();
            final double lat = (coord[1] as num).toDouble();
            return LatLng(lat, lng);
          }).toList();

          if (!mounted) return;
          
          // Adjust duration and distance based on transport mode
          double adjustedDuration = duration.toDouble();
          double adjustedDistance = distance.toDouble();
          
          switch (widget.transportMode) {
            case 'driving':
              // Use OSRM values as-is for driving
              break;
            case 'walking':
              // Walking: longer duration (10x slower), slightly longer distance (pedestrian routes)
              adjustedDuration = duration * 10.0; // Walking is much slower than driving
              adjustedDistance = distance * 1.1; // Walking routes can be slightly longer
              break;
            case 'transit':
              // Transit: longer duration due to stops, transfers, waiting
              adjustedDuration = duration * 1.8;
              break;
          }
          
          setState(() {
            routePoints = points;
            showRoute = true;
            routeDistance = '${(adjustedDistance / 1000).toStringAsFixed(1)} km';
            routeDuration = '${(adjustedDuration / 60).toStringAsFixed(0)} min';
            isLoading = false;
          });

          _fitBounds();
        } else {
          throw Exception('Route calculation error: ${data['message']}');
        }
      } else {
        throw Exception('API response error: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('OSRM API error: $e');
      _createSimpleRoute();
      
      if (!mounted) return;
      setState(() {
        showRoute = true;
        isLoading = false;
      });
    }
  }

  // Fallback method to create simplified straight-line route
  void _createSimpleRoute() {
    if (currentLocation == null || destinationLocation == null) return;

    routePoints = [currentLocation!, destinationLocation!];

    final double distanceInMeters = Geolocator.distanceBetween(
      currentLocation!.latitude,
      currentLocation!.longitude,
      destinationLocation!.latitude,
      destinationLocation!.longitude,
    );

    // Calculate duration based on transport mode
    double speedKmPerHour;
    switch (widget.transportMode) {
      case 'driving':
        speedKmPerHour = 50.0; // Average city driving speed
        break;
      case 'walking':
        speedKmPerHour = 5.0; // Average walking speed
        break;
      case 'transit':
        speedKmPerHour = 25.0; // Average transit speed (slower than driving)
        break;
      default:
        speedKmPerHour = 50.0;
    }

    final double distanceInKm = distanceInMeters / 1000;
    final double durationInMinutes = (distanceInKm / speedKmPerHour) * 60;

    routeDistance = '${distanceInKm.toStringAsFixed(1)} km (straight line)';
    routeDuration = '${durationInMinutes.toStringAsFixed(0)} min (estimate)';
  }

  // Adjust zoom to make the entire route visible
  void _fitBounds() {
    if (routePoints.isEmpty) return;

    final bounds = LatLngBounds.fromPoints(routePoints);
    try {
      mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: EdgeInsets.all(50),
        ),
      );
    } catch (e) {
      final lat = (bounds.north + bounds.south) / 2;
      final lng = (bounds.west + bounds.east) / 2;
      try {
        mapController.move(LatLng(lat, lng), 12.0);
      } catch (_) {}
    }
  }

  // Handle destination input
  Future<void> _handleDestinationInput(String destination) async {
    if (destination.trim().isEmpty) {
      setState(() {
        destinationLocation = null;
        showRoute = false;
        routePoints = [];
        routeDistance = null;
        routeDuration = null;
      });
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final location = await geocodeAddress(destination);
      if (location != null) {
        setState(() {
          destinationLocation = location;
          isLoading = false;
        });
        
        // Automatically show route when destination is set
        await _showRoute();
      } else {
        setState(() {
          isLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Address lookup unavailable. Please check your internet connection or try again later.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error searching for location')),
        );
      }
    }
  }
  Future<void> getAddress(double lat, double lon) async {
    // Validate coordinates
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      debugPrint('Invalid coordinates: lat=$lat, lon=$lon');
      setState(() {
        currentAddress = 'Invalid location coordinates';
      });
      return;
    }
    
    // Rate limiting: ensure at least 1 second between requests
    if (_lastNominatimRequest != null) {
      final timeSinceLastRequest = DateTime.now().difference(_lastNominatimRequest!);
      if (timeSinceLastRequest < _nominatimDelay) {
        await Future.delayed(_nominatimDelay - timeSinceLastRequest);
      }
    }
    _lastNominatimRequest = DateTime.now();
    final url =
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json';

    final response = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'SafeGoApp/1.0 (contact@safego.app)',
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://safego.app'
      },
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      setState(() {
        currentAddress = data['display_name'] ?? 'No address found';
      });
    } else if (response.statusCode == 403) {
      debugPrint('Nominatim reverse geocoding API access forbidden (403)');
      setState(() {
        currentAddress = 'Location: ${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}';
      });
    } else {
      debugPrint('Reverse geocoding failed with status: ${response.statusCode}');
      setState(() {
        currentAddress = 'Error: ${response.statusCode}';
      });
    }
  }

  // Method to get current location
  Future<void> _getCurrentLocation() async {
    if (!mounted) return;
    setState(() {
      isLoading = true;
    });

    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }
        return;
      }

      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            setState(() {
              isLoading = false;
            });
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }
        return;
      }

      // Get current location
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      if (!mounted) return;
      setState(() {
        currentLocation = LatLng(position.latitude, position.longitude);
        isLoading = false;
      });

      // Center map on current location
      if (currentLocation != null) {
        mapController.move(currentLocation!, 15.0);
        // Get address for the location
        getAddress(currentLocation!.latitude, currentLocation!.longitude);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.green,
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190), 
        foregroundColor: Colors.black, 
        centerTitle: true,
        title: Text(
          'SafeGo',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        elevation: 4,
        shadowColor: Colors.black54,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ProfileAvatar(
              size: 40,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const MyProfile()),
                );
              },
            ),
          ),
        ],
      ),

 ///////////////Start BottomNavigationBar//////////////////
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
          currentIndex: 0, 
          onTap: (index) {
            if (index == 0) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const HomePage()),
              );
            } else if (index == 1) {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const MyProfile()),
              );
            }
          },
          items: [
            BottomNavigationBarItem(
              icon: Icon(Icons.home),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person),
              label: 'Profile',
            ),
          ],
        ),
      ),
      
///////////// Floating SOS Button positioned closer to BottomNavigationBar ///////////
      floatingActionButton: SizedBox(

        width: 80, 
        height: 80, 
        child: FloatingActionButton(
          onPressed: () {
            sos.EmergencyAlert.show(context);
          },
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(40),
        side: const BorderSide(color: Colors.red, width: 5),
          ), // Black border
          child: const Text(
        'SOS',
        style: TextStyle(
          color: Colors.black,
          fontSize: 20, // Slightly larger text for bigger button
          fontWeight: FontWeight.bold,
        ),
          ),
        ),
      ),
      floatingActionButtonLocation: _CustomSOSButtonLocation(),

 ///////////////End BottomNavigationBar////////////////////////



///////////Main Body Layer that divides the top and bottom tabs////////////
      body: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[

        /////// Top sheet-like panel below the app bar, that shows the current location///////
          Container(
            width: double.infinity,
            height: 300,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.vertical(
              ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
              ],
            ),
            
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                const SizedBox(height: 5),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: Text(
                    "Click START button and scan your biometrics",
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 16,
                      fontWeight: FontWeight.normal,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            const Image(
                              image: AssetImage('assets/face.png'),
                              width: 100,
                              height: 100,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              "Scan your face",
                              style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            const Image(
                              image: AssetImage('assets/fingerprint.png'),
                              width: 100,
                              height: 100,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              "Scan your fingerprint",
                              style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: ElevatedButton(
                    onPressed: _enablebiometrics,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green, 
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 12),
                      minimumSize: const Size(double.infinity, 48), 
                    ),
                    child: const Text(
                      'START',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                )
                ],
              ),
            ),
          ),

          // Main content (live map)
          Expanded(
            child: Stack(
              children: [
                // FlutterMap widget
                FlutterMap(
                  mapController: mapController,
                  options: MapOptions(
                    initialCenter: currentLocation ?? LatLng(3.1390, 101.6869), // Default to Kuala Lumpur
                    initialZoom: 15.0,
                  ),
                  children: [
                    // Tile layer (map background)
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.flutterbiometrics',
                    ),

                    // Route layer
                    if (showRoute && routePoints.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: routePoints,
                            color: Colors.blue,
                            strokeWidth: 4.0,
                          ),
                        ],
                      ),

                    // Current location marker
                    if (currentLocation != null)
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: currentLocation!,
                            radius: 10,
                            color: Colors.blue.withOpacity(0.7),
                            borderColor: Colors.white,
                            borderStrokeWidth: 2,
                          ),
                        ],
                      ),

                    // Destination marker
                    if (destinationLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            width: 80.0,
                            height: 80.0,
                            point: destinationLocation!,
                            child: Column(
                              children: [
                                const Icon(
                                  Icons.location_on,
                                  color: Colors.red,
                                  size: 40,
                                ),
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(4),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: const Text(
                                    'Destination',
                                    style: TextStyle(fontSize: 10),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                    // Attribution widget for OpenStreetMap
                    RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution(
                          'OpenStreetMap contributors',
                          onTap: () => launchUrl(Uri.parse('https://openstreetmap.org/copyright')),
                        ),
                      ],
                      alignment: AttributionAlignment.bottomLeft,
                    ),
                  ],
                ),

                // Loading indicator
                if (isLoading)
                  Container(
                    color: Colors.black.withOpacity(0.3),
                    child: const Center(
                      child: CircularProgressIndicator(),
                    ),
                  ),

                // Refresh location button (positioned in top-right)
                Positioned(
                  top: 16,
                  right: 16,
                  child: FloatingActionButton(
                    mini: true,
                    onPressed: _getCurrentLocation,
                    backgroundColor: Colors.white,
                    child: const Icon(Icons.my_location, color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),

//////////END of Second Layer that divides the top and bottom tabs//////////////


/////////// Bottom sheet-like panel above the bottom navigation bar, that shows the input locations///////
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 255, 225, 190),
              borderRadius: const BorderRadius.vertical(
          top: Radius.circular(20),
              ),
              boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
              ],
            ),
            child: Column(
              children: [
          // Handle bar at the top of the bottom sheet
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 2),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Ongoing Trip",
                  style: TextStyle(color: Color.fromARGB(255, 44, 133, 47), fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                const Text(
                  "START LOCATION",
                  style: TextStyle(color: Colors.grey, fontWeight: FontWeight.normal),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.location_on, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AutoSizeText(
                        currentAddress,
                        style: TextStyle(fontSize: 18, color: Colors.black, fontWeight: FontWeight.bold),
                        maxLines: 2,
                        minFontSize: 12,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  "END LOCATION",
                  style: TextStyle(color: Colors.grey, fontWeight: FontWeight.normal),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.location_on, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AutoSizeText(
                        widget.destination,
                        style: TextStyle(fontSize: 18, color: Colors.black, fontWeight: FontWeight.bold),
                        maxLines: 2,
                        minFontSize: 12,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),

              ],
            ),
          ),
              ],
            ),
          ),

          ],
        ),
      );

  }

  // Debug method to show FCM test option after journey starts
  // Send direct FCM notification to specific device token
  Future<void> _sendDirectFCMNotification({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
  }) async {
    try {
      debugPrint('📲 Sending direct FCM to token: ${token.substring(0, 20)}...');
      
      // Create FCM notification document for server processing
      await FirebaseFirestore.instance
          .collection('fcm_notifications')
          .add({
        'to': token,
        'notification': {
          'title': title,
          'body': body,
          'sound': 'default',
          'badge': '1',
        },
        'data': data,
        'priority': 'high',
        'content_available': true,
        'timestamp': FieldValue.serverTimestamp(),
        'processed': false,
      });
      
      debugPrint('✅ Direct FCM notification queued successfully');
    } catch (e) {
      debugPrint('❌ Error sending direct FCM notification: $e');
    }
  }

  // Function to get address from coordinates for journey notifications
  Future<String> getAddressFromCoordinates(double lat, double lon) async {
    try {
      final url = 'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json';
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'SafeGo/1.0',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        String fullAddress = data['display_name'] ?? 'Address not found';
        
        // Trim long addresses to make them more readable
        if (fullAddress.length > 50) {
          List<String> parts = fullAddress.split(',');
          if (parts.length >= 3) {
            fullAddress = '${parts[0]}, ${parts[1]}, ${parts[2]}';
          }
        }
        
        return fullAddress;
      } else {
        debugPrint('Reverse geocoding failed with status: ${response.statusCode}');
        return 'Lat: ${lat.toStringAsFixed(6)}, Lon: ${lon.toStringAsFixed(6)}';
      }
    } catch (e) {
      debugPrint('Error getting address from coordinates: $e');
      return 'Lat: ${lat.toStringAsFixed(6)}, Lon: ${lon.toStringAsFixed(6)}';
    }
  }

  @override
  void dispose() {
    destinationController.dispose();
    super.dispose();
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
                        56.0 - 
                        (scaffoldGeometry.floatingActionButtonSize.height / 2); 
    
    return Offset(fabX, fabY);
  }
}
