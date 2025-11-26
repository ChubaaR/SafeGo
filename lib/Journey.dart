// lib/Journey.dart
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:safego/sos.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:safego/check_in.dart';
import 'package:safego/myProfile.dart';
import 'package:safego/homepage.dart';
import 'package:safego/auth_service.dart';
import 'package:safego/widgets/profile_avatar.dart';
import 'package:safego/notification_service.dart';
import 'package:safego/emercontpage.dart' as emer;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:safego/services/emergency_contact_notifications.dart';
import 'package:intl/intl.dart';
import 'package:safego/models/emergency_contact.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class Journey extends StatefulWidget {
  final String destination;
  final LatLng? currentLocation;
  final String currentAddress;
  final LatLng? destinationCoords; // Add destination coordinates parameter
  final String transportMode; // Add transport mode parameter

  const Journey({
    super.key,
    required this.destination,
    this.currentLocation,
    required this.currentAddress,
    this.destinationCoords, // Optional destination coordinates
    this.transportMode = 'driving', // Default to driving
  });

  @override
  JourneyState createState() => JourneyState();
}

class JourneyState extends State<Journey> {
  final MapController mapController = MapController();
  final TextEditingController destinationController = TextEditingController();
  int _bottomNavIndex = 0; // Track selected bottom navigation index
  
  LatLng? currentLocation;
  LatLng? destinationLocation;
  bool isLoading = false;
  String currentAddress = "Unknown";
  
  // Route variables
  List<LatLng> routePoints = [];
  bool showRoute = false;
  String? routeDistance;
  String? routeDuration;
  
  // Journey check-in variables
  Timer? _checkInTimer;
  bool _journeyStarted = false;
  int _checkInCount = 0;
  int _totalJourneyMinutes = 0;
  int _checkInIntervalMinutes = 1; // 1 minute intervals for testing
  DateTime? _journeyStartTime;
  
  // Background SOS monitoring variables
  Timer? _backgroundSOSTimer;
  Map<int, DateTime> _scheduledCheckIns = {}; // Track scheduled check-ins
  Map<int, bool> _checkInResponses = {}; // Track if check-ins were responded to
  final int _missedCheckInGracePeriod = 30; // 30 seconds grace period after scheduled check-in

  // Live location sharing variables
  Timer? _liveLocationTimer;
  List<EmergencyContact> _emergencyContacts = [];
  
  // Journey cancellation monitoring
  Timer? _cancellationMonitorTimer;
  
  // Arrival verification state
  bool _isVerifyingArrival = false;

  @override
  void initState() {
    super.initState();
    // Initialize with passed data
    currentLocation = widget.currentLocation;
    currentAddress = widget.currentAddress;
    destinationController.text = widget.destination;
    
    // Only fetch device location if no location was passed in from the caller
    if (widget.currentLocation == null) {
      _getCurrentLocation();
    }
    
    // If destination coordinates are provided, use them directly
    if (widget.destinationCoords != null) {
      destinationLocation = widget.destinationCoords;
      // Automatically show route when destination coordinates are available
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showRoute().then((_) {
          // Start the journey automatically when route is ready
          _startJourney();
        });
      });
    } else {
      // Otherwise, geocode the destination address
      _handleDestinationInput(widget.destination);
    }
    
    // Start monitoring for journey cancellation requests from other pages
    _startCancellationMonitoring();
  }
  
  // Monitor for journey cancellation requests from other parts of the app
  void _startCancellationMonitoring() {
    _cancellationMonitorTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_journeyStarted) {
        final isCancellationRequested = await JourneyManager.isCancellationRequested();
        if (isCancellationRequested) {
          // Cancellation was requested from another page, stop the journey
          debugPrint('Journey cancellation requested from external source - stopping journey');
          await JourneyManager.clearCancellationRequest(); // Clear the request immediately
          _stopJourneyForNavigation();
        }
      }
    });
  }

  // Method to convert address to coordinates (geocoding)
  Future<LatLng?> geocodeAddress(String address) async {
    final url =
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(address)}&format=json&limit=1';

    final response = await http.get(
      Uri.parse(url),
      headers: {
        'User-Agent': 'MyFlutterApp/1.0 (myemail@example.com)'
      },
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      if (data.isNotEmpty) {
        final lat = double.parse(data[0]['lat']);
        final lon = double.parse(data[0]['lon']);
        return LatLng(lat, lon);
      }
    }
    return null;
  }

  // Method to show route
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
        // OSRM doesn't have transit, fallback to driving but we'll adjust time later
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

    routeDistance = '${distanceInKm.toStringAsFixed(1)} km';
    routeDuration = '${durationInMinutes.toStringAsFixed(0)} min';
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
        
        // Start journey if this is coming from homepage (with coordinates)
        if (widget.destinationCoords != null) {
          _startJourney();
        }
      } else {
        setState(() {
          isLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location not found. Please try a different address.')),
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
    final url =
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json';

    final response = await http.get(
      Uri.parse(url),
      headers: {
        // REQUIRED by Nominatim usage policy
        'User-Agent': 'MyFlutterApp/1.0 (myemail@example.com)'
      },
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      setState(() {
        currentAddress = data['display_name'] ?? 'No address found';
      });
    } else {
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

  // Journey management methods
  void _startJourney() {
    if (routeDuration != null && !_journeyStarted) {
      setState(() {
        _journeyStarted = true;
        _journeyStartTime = DateTime.now();
        _checkInCount = 0;
      });
      
      // Register journey globally
      JourneyManager.setJourneyActive(true, startTime: _journeyStartTime);
      
      // Parse duration and set up check-in intervals
      _setupCheckInTimer();
      
      // Start background SOS monitoring for missed check-ins
      _startBackgroundSOSMonitoring();
      
      // Start live location sharing with emergency contacts
      _startLiveLocationSharing();
      
      // NOTE: exporting current location to external files/apps (e.g., emergsg) is disabled
      // by design to protect user privacy and avoid leaking location data.
      // _startExportingCurrentLocation();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Journey started! Live location sharing active with emergency contacts. Stay safe!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 4),
        ),
      );
      
      debugPrint('Journey started successfully with live location sharing');
    }
  }

  
  void _setupCheckInTimer() {
    if (routeDuration == null) return;
    
    // Extract minutes from routeDuration (format: "XX min")
    final durationText = routeDuration!.replaceAll(' min', '').replaceAll(' min (estimate)', '');
    _totalJourneyMinutes = int.tryParse(durationText) ?? 10;
    
    // Set check-in interval based on journey duration
    // If total journey < 10 minutes -> 5 minute intervals
    // If total journey >= 10 minutes -> 10 minute intervals
    if (_totalJourneyMinutes < 10) {
      _checkInIntervalMinutes = 1; // 5 minute intervals for short journeys
    } else {
      _checkInIntervalMinutes = 2; // 10 minute intervals for longer journeys
    }
    
    debugPrint('Check-in timer setup: ${_totalJourneyMinutes}min journey, ${_checkInIntervalMinutes}min intervals');
    
    // If journey is longer than check-in interval, set up periodic check-ins
    if (_totalJourneyMinutes > _checkInIntervalMinutes) {
      _scheduleNextCheckIn();
    }
  }
  
  void _scheduleNextCheckIn() {
    // Cancel any existing timer
    _checkInTimer?.cancel();
    
    // Check if journey is still active and we haven't exceeded the total time
    final elapsedMinutes = DateTime.now().difference(_journeyStartTime!).inMinutes;
    
    if (!_journeyStarted || elapsedMinutes >= _totalJourneyMinutes) {
      debugPrint('Journey completed or stopped - not scheduling next check-in');
      return;
    }
    
    // Calculate when the next check-in should occur
    final nextCheckInTime = DateTime.now().add(Duration(minutes: _checkInIntervalMinutes));
    final nextCheckInNumber = _checkInCount + 1;
    
    // Don't schedule if the next check-in would be beyond the journey end time
    final nextCheckInElapsed = nextCheckInTime.difference(_journeyStartTime!).inMinutes;
    
    if (nextCheckInElapsed > _totalJourneyMinutes) {
      debugPrint('Next check-in would exceed journey duration - completing journey');
      _completeJourney();
      return;
    }
    
    // Generate unique notification ID
    final notificationId = NotificationService.generateNotificationId(_journeyStartTime!, nextCheckInNumber);
    
    // Schedule notification to prompt user outside app
    NotificationService.scheduleCheckInNotification(
      id: notificationId,
      scheduledTime: nextCheckInTime,
      checkInNumber: nextCheckInNumber,
      // Use the configured interval so notifications reflect the actual next-check time
      remainingMinutes: _checkInIntervalMinutes,
    );
    
    // Track this check-in for background SOS monitoring
    _trackScheduledCheckIn(nextCheckInNumber, nextCheckInTime);
    
    debugPrint('Check-in #$nextCheckInNumber scheduled for $nextCheckInTime');
    
    // Schedule the next check-in after the interval
    _checkInTimer = Timer(Duration(minutes: _checkInIntervalMinutes), () async {
      if (_journeyStarted && mounted) {
        // Update check-in count to match the expected number
        setState(() {
          _checkInCount = nextCheckInNumber;
        });
        // Show check-in dialog automatically when timer expires
        await _performCheckIn();
      }
    });
  }
  
  // Handle check-in when timer expires or user responds to notification
  Future<void> _performCheckIn() async {
    // Start the global timer before showing dialog - this ensures timer runs even if user doesn't click notification
    debugPrint('Starting global check-in timer for check-in #$_checkInCount');
    JourneyCheckIn.startGlobalTimer(
      duration: 15, // 15 seconds countdown
      onExpired: () {
        // Global timer expired - SOS notification is already automatically scheduled to appear
        debugPrint('Global timer expired - SOS notification will be handled by scheduled background system');
      }
    );
    
    // Show the check-in dialog (timer already running)
    final bool checkInSuccess = await JourneyCheckIn.show(
      context, 
      _checkInCount, 
      _totalJourneyMinutes,
      _journeyStartTime!
    );
    
    if (checkInSuccess) {
      // Mark check-in as responded for background SOS monitoring
      _markCheckInAsResponded(_checkInCount);
      
      // Cancel the notification service SOS timer since user responded
      final notificationId = NotificationService.generateNotificationId(_journeyStartTime!, _checkInCount);
      NotificationService.markCheckInAsResponded(notificationId);
      
      debugPrint('Check-in #$_checkInCount completed successfully (including SOS cancellations)');
      
      // Check-in successful, schedule next check-in if journey continues
      final elapsedMinutes = DateTime.now().difference(_journeyStartTime!).inMinutes;
      
      // Schedule next check-in if there's still time remaining in the journey
      if (elapsedMinutes < _totalJourneyMinutes) {
        _scheduleNextCheckIn();
      } else {
        // Journey is complete, no more check-ins needed
        _completeJourney();
      }
    } else {
      // Check-in failed - but still continue journey with reduced check-in frequency
      debugPrint('Check-in #$_checkInCount failed, but journey continues');
      
      // Show warning but continue the journey
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Check-in $_checkInCount failed! Journey continues for safety. Please respond to next check-in.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 4),
        ),
      );
      
      // Continue scheduling check-ins even after failure to maintain safety monitoring
      final elapsedMinutes = DateTime.now().difference(_journeyStartTime!).inMinutes;
      if (elapsedMinutes < _totalJourneyMinutes) {
        _scheduleNextCheckIn();
      } else {
        _completeJourney();
      }
    }
  }
  
  void _completeJourney() {
    setState(() {
      _journeyStarted = false;
    });
    
    _checkInTimer?.cancel();
    
    // Unregister journey globally
    JourneyManager.setJourneyActive(false);
    
    // Stop background SOS monitoring
    _stopBackgroundSOSMonitoring();
    
    // Cancel all pending notifications for this journey
    _cancelAllJourneyNotifications();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Journey completed successfully! You had $_checkInCount check-ins.'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 4),
      ),
    );
  // Stop exporting current location (removed)
  }
  
  // Method to cancel all notifications for the current journey
  void _cancelAllJourneyNotifications() {
    if (_journeyStartTime != null) {
      // Cancel notifications for all potential check-ins
      for (int i = 1; i <= (_totalJourneyMinutes / _checkInIntervalMinutes).ceil() + 2; i++) {
        final notificationId = NotificationService.generateNotificationId(_journeyStartTime!, i);
        NotificationService.cancelNotification(notificationId);
        
        // CRITICAL FIX: Also cancel the scheduled SOS notification for this check-in
        final sosNotificationId = notificationId + 100000; // Same offset as used in NotificationService
        NotificationService.cancelNotification(sosNotificationId);
        debugPrint('Cancelled SOS notification with ID: $sosNotificationId for check-in #$i');
        
        // Cancel the scheduled SOS notification using the dedicated method
        NotificationService.cancelScheduledSOSNotification(i, _journeyStartTime!);
      }
      debugPrint('Cancelled all journey notifications and scheduled SOS notifications');
    }
    
    // Stop background notification monitoring
    NotificationService.stopBackgroundMonitoring();
    debugPrint('Stopped background notification monitoring');
  }
  
  // Background SOS Monitoring System for Missed Check-ins
  void _startBackgroundSOSMonitoring() {
    if (_journeyStartTime == null) return;
    
    // Start monitoring timer that checks every 30 seconds for missed check-ins//////////////////////////////////////////////
    _backgroundSOSTimer = Timer.periodic(Duration(seconds: 30), (timer) async {
      await _checkForMissedCheckIns();
    });
    
    debugPrint('Background SOS monitoring started for journey');
  }
  
  // Method to track scheduled check-ins for background monitoring
  void _trackScheduledCheckIn(int checkInNumber, DateTime scheduledTime) {
    _scheduledCheckIns[checkInNumber] = scheduledTime;
    _checkInResponses[checkInNumber] = false; // Initially not responded
    
    debugPrint('Tracking check-in #$checkInNumber scheduled for $scheduledTime');
  }
  
  // Method to mark check-in as responded (called when user completes check-in)
  void _markCheckInAsResponded(int checkInNumber) {
    _checkInResponses[checkInNumber] = true;
    debugPrint('Check-in #$checkInNumber marked as responded');
  }
  
  // Method to check for missed check-ins and trigger SOS if needed
  Future<void> _checkForMissedCheckIns() async {
    if (!_journeyStarted || _scheduledCheckIns.isEmpty) return;
    
    final now = DateTime.now();
    final checkInsToRemove = <int>[];
    
    // Create a copy of entries to avoid concurrent modification
    final entriesCopy = Map<int, DateTime>.from(_scheduledCheckIns);
    
    for (final entry in entriesCopy.entries) {
      final checkInNumber = entry.key;
      final scheduledTime = entry.value;
      final wasResponded = _checkInResponses[checkInNumber] ?? false;
      
      // Check if check-in was missed (past scheduled time + grace period and not responded)
      final timeSinceScheduled = now.difference(scheduledTime).inSeconds;
      
      if (!wasResponded && timeSinceScheduled > _missedCheckInGracePeriod) {
        // This check-in was missed! Trigger background SOS
        await _triggerBackgroundSOS(checkInNumber);
        
        // Mark for removal to avoid duplicate SOS alerts
        checkInsToRemove.add(checkInNumber);
      }
    }
    
    // Remove processed check-ins after iteration
    for (final checkIn in checkInsToRemove) {
      _scheduledCheckIns.remove(checkIn);
      _checkInResponses.remove(checkIn);
    }
  }
  
  // Method to trigger background SOS alert for missed check-in
  Future<void> _triggerBackgroundSOS(int missedCheckInNumber) async {
    try {
      // Get current user info
      String userName = 'User';
      String? userLocation;
      
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          
          if (userDoc.exists) {
            userName = userDoc.data()?['name'] ?? user.displayName ?? 'User';
          }
        } catch (e) {
          debugPrint('Error getting user info: $e');
        }
      }
      
      // Get current location
      try {
        Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        userLocation = '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}';
      } catch (e) {
        debugPrint('Error getting location for background SOS: $e');
        userLocation = 'Location unavailable';
      }
      
      // Format missed time
      final missedTime = DateFormat('HH:mm').format(DateTime.now());
      
      debugPrint('Background SOS alert triggered for missed check-in #$missedCheckInNumber for user: $userName at location: $userLocation');
      
      // Send missed check-in push notification
      await NotificationService.showMissedCheckInNotification(
        userName: userName,
        checkInNumber: missedCheckInNumber,
        missedTime: missedTime,
        userLocation: userLocation,
      );
      
      debugPrint('Missed check-in notification sent for $userName at $missedTime');
      
    } catch (e) {
      debugPrint('Error triggering background SOS: $e');
    }
  }
  
  // Stop background SOS monitoring
  void _stopBackgroundSOSMonitoring() {
    _backgroundSOSTimer?.cancel();
    _scheduledCheckIns.clear();
    _checkInResponses.clear();
    debugPrint('Background SOS monitoring stopped');
  }

  // Start live location sharing with emergency contacts
  Future<void> _startLiveLocationSharing() async {
    try {
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      // Get emergency contacts who have live location permission
      final contactsSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .collection('emergency_contacts')
          .where('allowShareLiveLocation', isEqualTo: true)
          .get();

      _emergencyContacts = contactsSnapshot.docs
          .map((doc) => EmergencyContact.fromFirestore(doc))
          .toList();

      if (_emergencyContacts.isEmpty) {
        debugPrint('No emergency contacts with live location permission found');
        return;
      }

      debugPrint('Starting live location sharing for ${_emergencyContacts.length} contacts');

      // Update location immediately
      await _updateLiveLocationForContacts();

      // Set up periodic updates every 30 seconds during journey
      _liveLocationTimer?.cancel();
      _liveLocationTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
        if (_journeyStarted && mounted) {
          await _updateLiveLocationForContacts();
        } else {
          timer.cancel();
        }
      });

    } catch (e) {
      debugPrint('Error starting live location sharing: $e');
    }
  }

  // Update live location for all emergency contacts with permission
  Future<void> _updateLiveLocationForContacts() async {
    try {
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null || _emergencyContacts.isEmpty) return;

      // Get current position
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      // Prepare route data for sharing
      List<Map<String, double>>? routeData;
      Map<String, double>? destinationData;

      if (routePoints.isNotEmpty) {
        routeData = routePoints.map((point) => {
          'lat': point.latitude,
          'lng': point.longitude,
        }).toList();
      }

      if (destinationLocation != null) {
        destinationData = {
          'lat': destinationLocation!.latitude,
          'lng': destinationLocation!.longitude,
        };
      }

      // Update live location with route information for each contact with permission
      for (EmergencyContact contact in _emergencyContacts) {
        if (contact.allowShareLiveLocation) {
          await EmergencyContactNotifications.updateLiveLocationWithRoute(
            uid: currentUser.uid,
            contact: contact,
            position: position,
            routePoints: routeData,
            destination: destinationData,
          );
        }
      }

      debugPrint('Live location with route updated for ${_emergencyContacts.length} contacts (${routePoints.length} route points)');
    } catch (e) {
      debugPrint('Error updating live location: $e');
    }
  }

  // Stop live location sharing
  void _stopLiveLocationSharing() {
    _liveLocationTimer?.cancel();
    _emergencyContacts.clear();
    debugPrint('Live location sharing stopped');
  }
  
  
  Future<void> _stopJourney() async {
    // Get current location to check if user reached destination
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      
      LatLng currentPos = LatLng(position.latitude, position.longitude);
      
      // Calculate distance to destination (in meters)
      double distanceToDestination = 0;
      if (destinationLocation != null) {
        distanceToDestination = Geolocator.distanceBetween(
          currentPos.latitude,
          currentPos.longitude,
          destinationLocation!.latitude,
          destinationLocation!.longitude,
        );
      }
      
      // Check if user is within 100 meters of destination (reasonable arrival threshold)
      if (distanceToDestination <= 100) {
        // User has reached destination - start verification process
        setState(() {
          _isVerifyingArrival = true;
        });
        
        _showImSafeDialog();
      } else {
        // User hasn't reached destination - keep journey active and show distance message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('You are ${(distanceToDestination / 1000).toStringAsFixed(1)}km from destination. Journey continues tracking for your safety.'),
            backgroundColor: Colors.blue,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      // Error getting location - keep journey active but show warning
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to get your location. Journey continues tracking for your safety.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),

        ),
      );
    }
  }
  
  void _showImSafeDialog() {
    // Show biometric authentication first, then the "I'm Safe" confirmation
    _showArrivalAuthenticationDialog();
  }
  
  // Send arrival notification with current time
  Future<void> _sendArrivalNotification() async {
    try {
      // Get current user name
      String userName = 'User';
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          
          if (userDoc.exists) {
            userName = userDoc.data()?['name'] ?? user.displayName ?? 'User';
          }
        } catch (e) {
          debugPrint('Error getting user info for arrival notification: $e');
        }
      }
      
      // Format current time
      final now = DateTime.now();
      final formattedTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      
      // Send notification
      await NotificationService.showArrivalNotification(
        userName: userName,
        arrivalTime: formattedTime,
      );
      
      debugPrint('Arrival notification sent for $userName at $formattedTime');
    } catch (e) {
      debugPrint('Error sending arrival notification: $e');
    }
  }

  // Send journey cancellation notification with current time and location
  Future<void> _sendJourneyCancellationNotification(String reason) async {
    try {
      // Get current user name
      String userName = 'User';
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          
          if (userDoc.exists) {
            userName = userDoc.data()?['name'] ?? user.displayName ?? 'User';
          }
        } catch (e) {
          debugPrint('Error getting user info for cancellation notification: $e');
        }
      }
      
      // Format current time
      final now = DateTime.now();
      final formattedTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      
      // Get current location for cancellation notification
      String? locationString;
      try {
        if (currentLocation != null) {
          locationString = '${currentLocation!.latitude.toStringAsFixed(6)}, ${currentLocation!.longitude.toStringAsFixed(6)}';
        }
      } catch (e) {
        debugPrint('Error getting location for cancellation notification: $e');
      }
      
      // Send notification
      await NotificationService.showJourneyCancelledNotification(
        userName: userName,
        cancelTime: formattedTime,
        currentLocation: locationString,
        destination: widget.destination,
        reason: reason,
      );
      
      debugPrint('Journey cancellation notification sent for $userName at $formattedTime, reason: $reason');
    } catch (e) {
      debugPrint('Error sending journey cancellation notification: $e');
    }
  }
  
  // Method to handle journey exit with biometric verification
  Future<void> _handleJourneyExit() async {
    if (_journeyStarted) {
      // Journey is active - require biometric verification
      _showExitVerificationDialog();
    } else {
      // Journey not started - can exit normally
      Navigator.pop(context);
    }
  }
  
  // Method to handle navigation with biometric verification (always required)
  Future<void> _handleProtectedNavigation(VoidCallback navigationCallback) async {
    // Always require biometric verification for navigation to HomePage and Profile
    _showNavigationVerificationDialog(navigationCallback);
  }
  
  void _showNavigationVerificationDialog(VoidCallback navigationCallback) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _NavigationVerificationDialog(
        onAuthenticationSuccess: () {
          Navigator.of(context).pop(); // Close verification dialog
          _stopJourneyForNavigation(); // Stop the journey when user navigates
          navigationCallback(); // Execute the original navigation
        },
        checkInCount: _checkInCount,
      ),
    );
  }
  
  void _stopJourneyForNavigation() {
    // Stop journey if it was active
    if (_journeyStarted) {
      setState(() {
        _journeyStarted = false;
      });
      
    _checkInTimer?.cancel();
    _stopLiveLocationSharing();
  // _exportLocationTimer removed
    
    // Stop background SOS monitoring - CRITICAL: This was missing!
    _stopBackgroundSOSMonitoring();      // Cancel all pending notifications for this journey
      _cancelAllJourneyNotifications();
      
      // Send journey cancellation notification to Device B
      _sendJourneyCancellationNotification('User navigation');
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Journey stopped - Navigation authenticated successfully.'),
          backgroundColor: Colors.blue,
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      // Journey wasn't active, just show authentication success
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Navigation authenticated successfully.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
    
    // Unregister journey globally and clear any cancellation requests
    JourneyManager.setJourneyActive(false);
    JourneyManager.clearCancellationRequest();
  }
  
  void _showArrivalAuthenticationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ArrivalAuthenticationDialog(
        onAuthenticationSuccess: _showImSafeConfirmationDialog,
        onAuthenticationCancelled: () {
          // Reset verification state when authentication is cancelled
          setState(() {
            _isVerifyingArrival = false;
          });
        },
        checkInCount: _checkInCount,
      ),
    );
  }
  
  void _showExitVerificationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _ExitVerificationDialog(
        onAuthenticationSuccess: () {
          // Stop the journey and exit
          setState(() {
            _journeyStarted = false;
          });
          _checkInTimer?.cancel();
          // Cancel all pending notifications for this journey
          _cancelAllJourneyNotifications();
          // Send journey cancellation notification to Device B
          _sendJourneyCancellationNotification('Journey exit by user');
          Navigator.pop(context); // Close verification dialog
          Navigator.pop(context); // Exit journey screen
        },
        checkInCount: _checkInCount,
      ),
    );
  }
  
  void _showImSafeConfirmationDialog() {
    // Send arrival notification before showing dialog
    _sendArrivalNotification();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: const BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                automaticallyImplyLeading: false,
                title: const Text(
                  'I\'m Safe',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                centerTitle: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: [
                  Icon(
                    Icons.check_circle,
                    color: Colors.green,
                    size: 48,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'You have safely arrived! Your emergency contacts have been notified!',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Arrival time: ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontSize: 14, color: Colors.green, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Total check-ins completed: $_checkInCount',
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                ),
                onPressed: () {
                  // Complete the journey successfully
                  setState(() {
                    _journeyStarted = false;
                    _isVerifyingArrival = false;
                  });
                  
                  _checkInTimer?.cancel();
                  _stopLiveLocationSharing();
                  
                  // Stop background SOS monitoring
                  _stopBackgroundSOSMonitoring();
                  
                  // Cancel all pending notifications for this journey
                  _cancelAllJourneyNotifications();
                  
                  // Unregister journey globally
                  JourneyManager.setJourneyActive(false);
                  
                  Navigator.of(context).pop(); // Close the dialog
                  // Navigate back to homepage and clear the navigation stack
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (context) => const HomePage()),
                    (Route<dynamic> route) => false,
                  );
                },
                child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper method to get transport mode icon
  IconData _getTransportIcon() {
    switch (widget.transportMode) {
      case 'driving':
        return Icons.directions_car;
      case 'walking':
        return Icons.directions_walk;
      case 'transit':
        return Icons.directions_transit;
      default:
        return Icons.directions;
    }
  }

  // Helper method to build action buttons
  Widget _buildActionButton({
    required IconData icon,
    double iconSize = 25,
  }) {
    return GestureDetector(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 70, // Increased width for a longer button
            height: 40,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color.fromARGB(255, 255, 241, 217),
              border: Border.all(
                color: Colors.black12,
                width: 1,
              ),
            ),
            child: Center(
              child: Icon(
                icon,
                color: Colors.black,
                size: iconSize,
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 50, // Match button width for longer label
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent unauthorized exit during journey
      onPopInvoked: (didPop) {
        if (!didPop) {
          // Handle all types of exit attempts (swipe or back button) through biometric verification
          _handleJourneyExit();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.green,
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190), // Override AppBar background color
        foregroundColor: Colors.black, // Override AppBar icon/text color
        centerTitle: true,
        title: Text(
          'SafeGo',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        elevation: 4,
        shadowColor: Colors.black54,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleJourneyExit,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ProfileAvatar(
              size: 40,
              onTap: () {
                _handleProtectedNavigation(() {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const MyProfile()),
                  );
                });
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
          backgroundColor: const Color.fromARGB(255, 255, 225, 190), // Override BottomNavigationBar background color
          selectedItemColor: Colors.black, // Override selected item color
          unselectedItemColor: Colors.grey, // Override unselected item color
          currentIndex: _bottomNavIndex, // Track selected tab
          onTap: (index) {
            setState(() {
              _bottomNavIndex = index;
            });
            if (index == 0) {
              // Navigate to HomePage with verification
              _handleProtectedNavigation(() {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const HomePage()),
                );
              });
            } else if (index == 1) {
              // Navigate to MyProfile with verification
              _handleProtectedNavigation(() {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const MyProfile()),
                );
              });
            } else if (index == 2) {
              // Navigate directly to Emergency Contacts (emer.HomePage) without biometric verification
              // Leave the journey running so contacts can view live location
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const emer.HomePage()),
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
            BottomNavigationBarItem(
              icon: Icon(Icons.contact_phone),
              label: 'Contacts',
            ),
          ],
        ),
      ),
      
///////////// Floating SOS Button positioned closer to BottomNavigationBar ///////////
      floatingActionButton: SizedBox(
        // Increased size for bigger button
        width: 80, 
        height: 80, 
        child: FloatingActionButton(
          onPressed: () {
            EmergencyAlert.show(context);
          },
          backgroundColor: Colors.white,
          heroTag: "journeySosButton", // Unique hero tag
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
                    heroTag: "journeyLocationRefreshButton", // Unique hero tag
                    child: const Icon(Icons.my_location, color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),

//////////END of Second Layer that divides the top and bottom tabs//////////////


////////// Bottom sheet-like panel above the bottom navigation bar, that shows the input locations///////
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
            margin: const EdgeInsets.symmetric(vertical: 6),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _journeyStarted ? "Journey in Progress" : "Journey Ready",
                      style: TextStyle(
                        color: _journeyStarted 
                          ? Color.fromARGB(255, 44, 133, 47) 
                          : Color.fromARGB(255, 100, 100, 100),
                        fontWeight: FontWeight.bold
                      ),
                    ),
                    if (_journeyStarted)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.circle,
                                size: 12,
                                color: Colors.green,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Check-ins: $_checkInCount',
                                style: TextStyle(
                                  color: Colors.green,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          if (_checkInTimer != null && _checkInTimer!.isActive)
                            Row(
                              children: [
                                Icon(
                                  Icons.schedule,
                                  size: 12,
                                  color: Colors.orange,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'Next: ${_checkInIntervalMinutes}min',
                                  style: TextStyle(
                                    color: Colors.orange,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                  ],
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
                const SizedBox(height: 6),
                
                // Journey control buttons
                if (showRoute && routeDistance != null && routeDuration != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [

                        if (_journeyStarted)
                        SizedBox(
                          width: 350, // Set the desired width for a longer button
                          child: ElevatedButton.icon(
                          onPressed: _isVerifyingArrival ? null : _stopJourney, // Disable during verification
                          icon: Icon(_isVerifyingArrival ? Icons.hourglass_empty : Icons.stop, size: 20),
                          label: Text(_isVerifyingArrival ? 'VERIFYING ARRIVAL...' : 'I\'VE ARRIVED'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            side: BorderSide(color: Colors.green, width: 1.5),
                          ),
                          ),
                        ),

                    ],
                  ),
                  const SizedBox(height: 16),
                ],

                // Time and distance display
                if (showRoute && routeDistance != null && routeDuration != null) ...[
                  Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Row(
                    children: [
                      Icon(Icons.timer, color: Colors.black),
                      const SizedBox(width: 8),
                      Text(
                      routeDuration!,
                      style: TextStyle(fontSize: 14, color: Colors.black),
                      ),
                    const SizedBox(width: 16),
                    ],
                    
                    ),
                    Row(
                    children: [
                      Icon(Icons.map_outlined, color: Colors.black),
                      const SizedBox(width: 8),
                      Text(
                      routeDistance!,
                      style: TextStyle(fontSize: 14, color: Colors.black),
                      ),
                    const SizedBox(width: 16),
                    ],
                    ),
                    _buildActionButton(
                      icon: _getTransportIcon(),
                      iconSize: 20,
                    ),
                    // Emergency Contacts button removed from sheet — available from bottom navigation
                  ],
                  ),
                ],
                const SizedBox(height: 25),
              ],
            ),
          ),
              ],
            ),
          ),


          ],
        ),
      ), // Close Scaffold
    ); // Close PopScope

  }

  @override
  void dispose() {
    destinationController.dispose();
    _checkInTimer?.cancel();
    _cancellationMonitorTimer?.cancel();
    
    // Stop background SOS monitoring
    _stopBackgroundSOSMonitoring();
    
    // Stop live location sharing
    _stopLiveLocationSharing();
    
    // Cancel all pending notifications when widget is disposed
    if (_journeyStarted) {
      _cancelAllJourneyNotifications();
    }
    
    super.dispose();
  }
}

// Authentication dialog widget for arrival verification
class _ArrivalAuthenticationDialog extends StatefulWidget {
  final VoidCallback onAuthenticationSuccess;
  final VoidCallback? onAuthenticationCancelled;
  final int checkInCount;

  const _ArrivalAuthenticationDialog({
    required this.onAuthenticationSuccess,
    this.onAuthenticationCancelled,
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
          widget.onAuthenticationCancelled?.call(); // Reset verification state
          
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
                  'Verify Arrival',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.black),
                  onPressed: () {
                    // Reset verification state when dialog is closed without authentication
                    Navigator.of(context).pop();
                    widget.onAuthenticationCancelled?.call();
                  },
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
                    'Please verify your identity to confirm safe arrival at your destination.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.black),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Check-ins completed: ${widget.checkInCount}',
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
                        onPressed: () => Navigator.of(context).pop(),
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

// Navigation verification dialog widget for protecting navigation during journey
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
        
        // Call the success callback to allow navigation
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
                  'Exit Journey',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.black),
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
                    Icons.security,
                    color: Colors.amber,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Please verify your identity to exit the active journey.',
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
