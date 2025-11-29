import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'livelocation.dart' as live;
import '../notification_service.dart';
import 'emergency_contact_sign_in.dart';
import 'myProfile.dart';




// Minimal stubs for services/models that exist in safego but not in emersg.
class SavedLocation {
  final String id;
  final String name;
  final String address;
  final ll.LatLng coordinates;
  final String type;

  SavedLocation({required this.id, required this.name, required this.address, required this.coordinates, this.type = 'other'});
}

class SavedLocationsService {
  Future<List<SavedLocation>> getSavedLocations() async => [];
  Future<Map<String, SavedLocation?>> getQuickAccessLocations() async => {'home': null, 'office': null};
  Future<String?> saveLocation({required String name, required String address, required double latitude, required double longitude, required String type}) async => 'id';
  Future<void> deleteLocation(String id) async {}
}

class UserPreferencesService {
  Future<Map<String, SavedLocation?>> getDefaultLocations() async => {'home': null, 'work': null};
  Future<bool> saveDefaultHomeLocation(SavedLocation location) async => true;
  Future<bool> saveDefaultWorkLocation(SavedLocation location) async => true;
  Future<void> clearDefaultHomeLocation() async {}
  Future<void> clearDefaultWorkLocation() async {}
}

class FaceScan extends StatelessWidget {
  final String destination;
  final ll.LatLng? currentLocation;
  final String currentAddress;
  final ll.LatLng? destinationCoords;
  final String transportMode;

  const FaceScan({super.key, required this.destination, this.currentLocation, required this.currentAddress, this.destinationCoords, required this.transportMode});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Face Scan (stub)')),
      body: Center(child: Text('Starting journey to $destination')),
    );
  }
}

class EmergencyAlert {
  static void show(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('SOS'),
        content: const Text('Emergency alert (stub)'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final TextEditingController destinationController = TextEditingController();
  ll.LatLng? currentLocation;
  
  // Rate limiting for Nominatim API
  static DateTime? _lastNominatimRequest;
  static const _nominatimDelay = Duration(seconds: 1);
  final SavedLocationsService _savedLocationsService = SavedLocationsService();
  final MapController mapController = MapController();
  String currentAddress = 'Unknown location';
  bool isLoading = false;
  bool isSearching = false;
  List<Map<String, dynamic>> locationSuggestions = [];
  OverlayEntry? _overlayEntry;
  final FocusNode _focusNode = FocusNode();
  Timer? _debounceTimer;

  ll.LatLng? selectedDestinationCoords;
  String? selectedDestinationName;
  String selectedTransportMode = 'driving';

  final TextEditingController location1Controller = TextEditingController();
  final TextEditingController location2Controller = TextEditingController();
  SavedLocation? selectedLocation1;
  SavedLocation? selectedLocation2;

 

  List<SavedLocation> savedLocations = [];

  String? _lastContactAddedName;
  String _userName = 'Emergency Contact';
  StreamSubscription<QuerySnapshot>? _journeyNotificationSubscription;
  StreamSubscription<QuerySnapshot>? _emergencyNotificationSubscription;
  StreamSubscription<QuerySnapshot>? _checkinNotificationSubscription;
  String? _lastEmergencyAlert;
  String? _lastMissedCheckInAlert;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    _startWatchingSafegoFile();
    _lastContactAddedName = null;
    _lastJourneyStartedInfo = null;
    // Also attempt to load any existing notifications that may have been

    _loadContactNotificationIfAvailable();
    _loadJourneyStartedNotificationIfAvailable();
    
    // Set up auth state listener to only start Firebase listeners when authenticated
    _setupAuthStateListener();
  }
  
  void _setupAuthStateListener() {
    debugPrint('🔧 Setting up auth state listener in emergency homepage');
    FirebaseAuth.instance.authStateChanges().listen((User? user) {
      if (user != null) {
        debugPrint('🎧 User authenticated (${user.uid}) - Setting up Firebase listeners');
        debugPrint('📧 User email: ${user.email}');
        debugPrint('👤 User displayName: ${user.displayName}');
        _loadUserName();
        _startFirebaseJourneyListener();
        _startFirebaseEmergencyListener();
        _startFirebaseMissedCheckinListener();
        // Initialize Device B emergency page listeners for customized journey notifications
        debugPrint('🚀 Calling NotificationService.initializeEmergencyPageListeners()');
        NotificationService.initializeEmergencyPageListeners();
      } else {
        debugPrint('❌ User logged out - stopping Firebase listeners');
        _stopFirebaseListeners();
      }
    });
  }
  
  void _stopFirebaseListeners() {
    _journeyNotificationSubscription?.cancel();
    _emergencyNotificationSubscription?.cancel();
    _checkinNotificationSubscription?.cancel();
    debugPrint('🛑 Firebase listeners stopped for user logout');
  }

  Future<void> _loadUserName() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        // First try to get from Firebase Auth displayName
        String? name = user.displayName;
        
        // If displayName is empty, try to get from Firestore
        if (name == null || name.isEmpty) {
          final doc = await FirebaseFirestore.instance
              .collection('emergency_contacts')
              .doc(user.uid)
              .get();
          
          if (doc.exists) {
            name = doc.data()?['name'] as String?;
          }
        }
        
        if (mounted) {
          setState(() {
            _userName = name?.isNotEmpty == true ? name! : 'Emergency Contact';
          });
        }
      }
    } catch (e) {
      print('Error loading user name: $e');
    }
  }

  List<StreamSubscription<FileSystemEvent>> _safegoWatcherSubs = [];
  String? _lastJourneyStartedInfo;

  void _startWatchingSafegoFile() {
    try {
      // Primary project folder
      final primaryDir = Directory(r'C:\Users\chuba\Desktop\safego\safego');
      if (primaryDir.existsSync()) {
        // Listen to all events (create/modify/rename) so we catch atomic
        // rename operations and new files written by safego.
        final sub = primaryDir.watch().listen((event) async {
          if (event.path.endsWith('.current_location.json')) {
            await _loadSafegoCurrentLocationIfAvailable();
          }
          if (event.path.endsWith('.contact_added.json') || event.path.endsWith('.contact_tmp') || event.path.endsWith('.contact_added.json')) {
            await _loadContactNotificationIfAvailable();
          }
          if (event.path.endsWith('.journey_started.json')) {
            await _loadJourneyStartedNotificationIfAvailable();
          }
        });
        _safegoWatcherSubs.add(sub);
      }

      // Fallback LOCALAPPDATA folder (where safego may write when workspace is read-only)
      final localApp = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['HOME'];
      if (localApp != null && localApp.isNotEmpty) {
        final fallbackDir = Directory('$localApp${Platform.pathSeparator}safego');
        if (fallbackDir.existsSync()) {
          final sub2 = fallbackDir.watch().listen((event) async {
            if (event.path.endsWith('.current_location.json')) {
              await _loadSafegoCurrentLocationIfAvailable();
            }
            if (event.path.endsWith('contact_added.json') || event.path.endsWith('.contact_added.json') || event.path.endsWith('.contact_tmp')) {
              await _loadContactNotificationIfAvailable();
            }
            if (event.path.endsWith('.journey_started.json')) {
              await _loadJourneyStartedNotificationIfAvailable();
            }
          });
          _safegoWatcherSubs.add(sub2);
        }
      }

      // Also watch the workspace folder for the contact notification file
      final workspaceDir = Directory(r'C:\Users\chuba\Desktop\safego\safego');
      if (workspaceDir.existsSync()) {
        final sub3 = workspaceDir.watch().listen((event) async {
          if (event.path.endsWith('.contact_added.json') || event.path.endsWith('contact_added.json') || event.path.endsWith('.contact_tmp')) {
            await _loadContactNotificationIfAvailable();
          }
          if (event.path.endsWith('.journey_started.json')) {
            await _loadJourneyStartedNotificationIfAvailable();
          }
        });
        _safegoWatcherSubs.add(sub3);
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _loadInitialData() async {
    await _getCurrentLocation();
    try {
      savedLocations = await _savedLocationsService.getSavedLocations();
      final quick = await _savedLocationsService.getQuickAccessLocations();
      selectedLocation1 = quick['home'];
      selectedLocation2 = quick['office'];
    } catch (e) {
      print('Error loading initial data: $e');
    }

    if (mounted) setState(() {});
  }

  Future<void> _showLocationSaveDialog({required ll.LatLng coordinates, required String address}) async {
    final nameController = TextEditingController(text: address);
    String selectedType = 'other';

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save location'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: selectedType,
              items: const [
                DropdownMenuItem(value: 'home', child: Text('Home')),
                DropdownMenuItem(value: 'office', child: Text('Work')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (v) => selectedType = v ?? 'other',
              decoration: const InputDecoration(labelText: 'Type'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Save')),
        ],
      ),
    );

    if (result == true) {
      final id = await _savedLocationsService.saveLocation(
        name: nameController.text.trim(),
        address: address,
        latitude: coordinates.latitude,
        longitude: coordinates.longitude,
        type: selectedType,
      );

      if (id != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location saved'), backgroundColor: Colors.green));
        savedLocations = await _savedLocationsService.getSavedLocations();
        setState(() {});
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to save location'), backgroundColor: Colors.red));
      }
    }
  }



  Future<void> _onMapLongPress(ll.LatLng point) async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location detected! Getting address...'), duration: Duration(seconds: 2), backgroundColor: Colors.blue));
    String address = 'Unknown Location';
    
    // Rate limiting: ensure at least 1 second between requests
    if (_lastNominatimRequest != null) {
      final timeSinceLastRequest = DateTime.now().difference(_lastNominatimRequest!);
      if (timeSinceLastRequest < _nominatimDelay) {
        await Future.delayed(_nominatimDelay - timeSinceLastRequest);
      }
    }
    _lastNominatimRequest = DateTime.now();
    
    try {
      final url = 'https://nominatim.openstreetmap.org/reverse?lat=${point.latitude}&lon=${point.longitude}&format=json&addressdetails=1';
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'SafeGoEmergencyApp/1.0 (contact@safego.app)',
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://safego.app'
      });
      if (resp.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(resp.body);
        address = data['display_name']?.toString() ?? address;
        if (data['address'] != null && data['address'] is Map<String, dynamic>) {
          address = _formatMalaysianAddress(data['address'] as Map<String, dynamic>, address);
        }
      } else if (resp.statusCode == 403) {
        debugPrint('Nominatim API access forbidden (403). Using coordinates.');
        address = 'Location: ${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}';
      } else {
        debugPrint('Geocoding failed with status: ${resp.statusCode}');
      }
    } catch (e) {
      // ignore and keep coordinate go back
    }

    await _showLocationSaveDialog(coordinates: point, address: address);
  }

  /// Attempts to read a JSON file exported by the safego app at
  /// 
  Future<void> _loadSafegoCurrentLocationIfAvailable() async {
    try {
      // Try primary safego workspace path first
  final primaryPath = r'C:\Users\chuba\Desktop\safego\safego\.current_location.json';
  File file = File(primaryPath);
      if (!await file.exists()) {
        // Try fallback in LOCALAPPDATA\safego\.current_location.json
        final localApp = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['HOME'] ?? '.';
        final fallbackPath = '$localApp${Platform.pathSeparator}safego${Platform.pathSeparator}.current_location.json';
        final fallbackFile = File(fallbackPath);
        if (await fallbackFile.exists()) file = fallbackFile; else return;
      }

      final contents = await file.readAsString();
      final Map<String, dynamic> data = json.decode(contents) as Map<String, dynamic>;
      final latNum = data['lat'];
      final lonNum = data['lon'];
      final addr = data['address']?.toString() ?? '';
      if (latNum != null && lonNum != null) {
        final lat = (latNum as num).toDouble();
        final lon = (lonNum as num).toDouble();
        if (mounted) {
          setState(() {
            currentLocation = ll.LatLng(lat, lon);
            if (addr.isNotEmpty) currentAddress = addr;
          });
        }
      }
    } catch (e) {
      // Ignore failures — fallback to live device location
    }
  }
  Future<void> _loadContactNotificationIfAvailable() async {
    try {
      // Try workspace first
      final primaryPath = r'C:\Users\chuba\Desktop\safego\safego\.contact_added.json';
      File file = File(primaryPath);
      if (!await file.exists()) {
        final localApp = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['HOME'] ?? '.';
        final fallbackPath = '$localApp${Platform.pathSeparator}safego${Platform.pathSeparator}contact_added.json';
        final fallbackFile = File(fallbackPath);
        if (await fallbackFile.exists()) file = fallbackFile; else return;
      }

      final contents = await file.readAsString();
      final Map<String, dynamic> data = json.decode(contents) as Map<String, dynamic>;
      final name = data['name']?.toString() ?? '';
      if (name.isNotEmpty) {
        if (mounted) {
          setState(() {
            _lastContactAddedName = name;
          });

          // show for 6 seconds
          Future.delayed(const Duration(seconds: 6)).then((_) {
            if (mounted) setState(() => _lastContactAddedName = null);
          });
        }
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _loadJourneyStartedNotificationIfAvailable() async {
    try {
      // Try workspace first
      final primaryPath = r'C:\Users\chuba\Desktop\safego\safego\.journey_started.json';
      File file = File(primaryPath);
      if (!await file.exists()) {
        final localApp = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['HOME'] ?? '.';
        final fallbackPath = '$localApp${Platform.pathSeparator}safego${Platform.pathSeparator}.journey_started.json';
        final fallbackFile = File(fallbackPath);
        if (await fallbackFile.exists()) file = fallbackFile; else return;
      }

      final contents = await file.readAsString();
      final Map<String, dynamic> data = json.decode(contents) as Map<String, dynamic>;
      final userName = data['userName']?.toString() ?? '';
      final destination = data['destination']?.toString() ?? '';
      final startTime = data['startTime']?.toString() ?? '';
      
      if (userName.isNotEmpty && destination.isNotEmpty) {
        final journeyInfo = '$userName started a journey to $destination at $startTime';
        if (mounted) {
          setState(() {
            _lastJourneyStartedInfo = journeyInfo;
          });

          // Also show the notification
          await NotificationService.showJourneyStartedNotification(
            userName: userName,
            destination: destination,
            startTime: startTime,
          );

          // show for 8 seconds
          Future.delayed(const Duration(seconds: 8)).then((_) {
            if (mounted) setState(() => _lastJourneyStartedInfo = null);
          });
        }
      }
    } catch (e) {
      // ignore
    }
  }

  // Listen for journey started notifications from Firebase
  void _startFirebaseJourneyListener() {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Track when listener starts to avoid showing old notifications
      bool isFirstSnapshot = true;

      _journeyNotificationSubscription = FirebaseFirestore.instance
          .collection('journey_notifications')
          .where('toUserId', isEqualTo: user.uid)
          .where('read', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .limit(10)
          .snapshots()
          .listen((snapshot) {
        debugPrint('📨 Journey notifications listener triggered: ${snapshot.docs.length} documents, isFirst: $isFirstSnapshot');
        
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data() as Map<String, dynamic>;
            final type = data['type']?.toString() ?? '';
            final userName = data['userName']?.toString() ?? 'Someone';
            
            // Skip old notifications from before this session started
            if (isFirstSnapshot) {
              debugPrint('⏭️ First snapshot - marking as seen but not showing: ${change.doc.id}');
              // Mark old notifications as read without showing them
              change.doc.reference.update({'read': true}).catchError((e) {
                debugPrint('❌ Error marking old notification as read: $e');
              });
              continue;
            }
            
            debugPrint('🔔 New notification: type=$type, user=$userName');
            
            if (type == 'journey_started') {
              final destination = data['destination']?.toString() ?? 'Unknown';
              final startTime = data['startTime']?.toString() ?? '';
              
              // Show the notification and banner
              _showJourneyStartedFromFirebase(userName, destination, startTime);
            } else if (type == 'emergency_sos') {
              final alertTime = data['startTime']?.toString() ?? '';
              final currentLocation = data['currentLocation']?.toString() ?? 'Unknown location';
              final additionalMessage = data['additionalMessage']?.toString() ?? '';
              
              debugPrint('🚨 EMERGENCY SOS received from $userName at $alertTime');
              
              // Show the emergency notification and banner
              _showEmergencyAlertFromFirebase(userName, alertTime, currentLocation, additionalMessage);
            }
            
            // Mark as read
            change.doc.reference.update({'read': true}).catchError((e) {
              debugPrint('❌ Error marking notification as read: $e');
            });
          }
        }
        
        // After processing first snapshot, start showing new notifications
        if (isFirstSnapshot) {
          isFirstSnapshot = false;
          debugPrint('✅ First snapshot processed - now listening for new notifications only');
        }
      });
    } catch (e) {
      debugPrint('Error setting up Firebase journey listener: $e');
    }
  }

  // Show journey started notification from Firebase
  Future<void> _showJourneyStartedFromFirebase(String userName, String destination, String startTime) async {
    try {
      final journeyInfo = '$userName started a journey to $destination at $startTime';
      
      if (mounted) {
        setState(() {
          _lastJourneyStartedInfo = journeyInfo;
        });

        // Show the notification
        await NotificationService.showJourneyStartedNotification(
          userName: userName,
          destination: destination,
          startTime: startTime,
        );

        // Hide banner after 8 seconds
        Future.delayed(const Duration(seconds: 8)).then((_) {
          if (mounted) setState(() => _lastJourneyStartedInfo = null);
        });
      }
    } catch (e) {
      debugPrint('Error showing journey started from Firebase: $e');
    }
  }

  // Listen for emergency SOS notifications from Firebase
  void _startFirebaseEmergencyListener() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      debugPrint('🚨 Setting up Firebase emergency listener for user: ${user.uid}');
      
      // Get this device's FCM token to match against targetToken
      String? currentDeviceToken;
      try {
        currentDeviceToken = await FirebaseMessaging.instance.getToken();
        debugPrint('📱 Device B FCM token for listening: ${currentDeviceToken != null && currentDeviceToken.length > 20 ? "${currentDeviceToken.substring(0, 20)}..." : (currentDeviceToken ?? "null")}');
      } catch (e) {
        debugPrint('❌ Failed to get FCM token: $e');
      }

      _emergencyNotificationSubscription = FirebaseFirestore.instance
          .collection('emergency_notifications')
          .where('type', isEqualTo: 'sos_alert')
          .where('read', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .limit(10)
          .snapshots()
          .listen((snapshot) {
        debugPrint('📨 Emergency notifications snapshot received: ${snapshot.docs.length} documents');
        
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data() as Map<String, dynamic>;
            final targetToken = data['targetToken']?.toString();
            final userName = data['userName']?.toString() ?? 'SafeGo User';
            final alertTime = data['alertTime']?.toString() ?? '';
            final currentLocation = data['currentLocation']?.toString() ?? 'Unknown location';
            final additionalMessage = data['additionalMessage']?.toString() ?? '';
            
            debugPrint('🚨 SOS alert found: $userName at $alertTime');
            debugPrint('🎯 Target token: ${targetToken != null && targetToken.length > 20 ? "${targetToken.substring(0, 20)}..." : (targetToken ?? "null")}');
            debugPrint('📱 My token: ${currentDeviceToken != null && currentDeviceToken.length > 20 ? "${currentDeviceToken.substring(0, 20)}..." : (currentDeviceToken ?? "null")}');
            
            // Check if this notification is for this device
            if (targetToken != null && currentDeviceToken != null && targetToken == currentDeviceToken) {
              debugPrint('✅ SOS alert matches this device - showing notification');
              
              // Show the emergency notification and banner
              _showEmergencyAlertFromFirebase(userName, alertTime, currentLocation, additionalMessage);
              
              // Mark as read
              change.doc.reference.update({'read': true});
            } else {
              debugPrint('⚠️ SOS alert not for this device - skipping');
            }
          }
        }
      });
    } catch (e) {
      debugPrint('❌ Error setting up Firebase emergency listener: $e');
    }
  }

  // Show emergency SOS alert from Firebase
  Future<void> _showEmergencyAlertFromFirebase(String userName, String alertTime, String currentLocation, String additionalMessage) async {
    try {
      final emergencyInfo = '🚨 EMERGENCY: $userName sent SOS alert at $alertTime';
      
      if (mounted) {
        setState(() {
          _lastEmergencyAlert = emergencyInfo;
        });

        // Show the emergency notification
        await NotificationService.showEmergencySOSNotification(
          userName: userName,
          alertTime: alertTime,
          userLocation: currentLocation,
        );

        // Hide banner after 15 seconds (longer for emergency alerts)
        Future.delayed(const Duration(seconds: 15)).then((_) {
          if (mounted) setState(() => _lastEmergencyAlert = null);
        });

        debugPrint('✅ Emergency SOS notification displayed for $userName');
      }
    } catch (e) {
      debugPrint('❌ Error showing emergency SOS from Firebase: $e');
    }
  }

  // Listen for missed check-in notifications from Firebase
  void _startFirebaseMissedCheckinListener() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      debugPrint('⚠️ Setting up Firebase missed check-in listener for user: ${user.uid}');
      
      bool isFirstSnapshot = true;

      _checkinNotificationSubscription = FirebaseFirestore.instance
          .collection('checkin_notifications')
          .where('toUserId', isEqualTo: user.uid)
          .where('read', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .limit(10)
          .snapshots()
          .listen((snapshot) {
        debugPrint('📨 Missed check-in notifications listener triggered: ${snapshot.docs.length} documents, isFirst: $isFirstSnapshot');
        
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data() as Map<String, dynamic>;
            final type = data['type']?.toString() ?? '';
            final userName = data['userName']?.toString() ?? 'Someone';
            
            // Skip old notifications from before this session started
            if (isFirstSnapshot) {
              debugPrint('⏭️ First snapshot - marking missed check-in as seen but not showing: ${change.doc.id}');
              // Mark old notifications as read without showing them
              change.doc.reference.update({'read': true}).catchError((e) {
                debugPrint('❌ Error marking old missed check-in notification as read: $e');
              });
              continue;
            }
            
            debugPrint('🔔 New missed check-in notification: type=$type, user=$userName');
            
            if (type == 'missed_checkin') {
              final checkInNumber = data['checkInNumber'] ?? 0;
              final missedTime = data['missedTime']?.toString() ?? '';
              final currentLocation = data['currentLocation']?.toString() ?? 'Location unavailable';
              
              debugPrint('⚠️ MISSED CHECK-IN received from $userName for check-in #$checkInNumber at $missedTime');
              
              // Show the missed check-in notification and banner
              _showMissedCheckinFromFirebase(userName, checkInNumber, missedTime, currentLocation);
            }
            
            // Mark as read
            change.doc.reference.update({'read': true}).catchError((e) {
              debugPrint('❌ Error marking missed check-in notification as read: $e');
            });
          }
        }
        
        // After processing first snapshot, start showing new notifications
        if (isFirstSnapshot) {
          isFirstSnapshot = false;
          debugPrint('✅ First missed check-in snapshot processed - now listening for new notifications only');
        }
      });
    } catch (e) {
      debugPrint('❌ Error setting up Firebase missed check-in listener: $e');
    }
  }

  // Show missed check-in notification from Firebase
  Future<void> _showMissedCheckinFromFirebase(String userName, int checkInNumber, String missedTime, String currentLocation) async {
    try {
      final missedCheckinInfo = '⚠️ MISSED CHECK-IN: $userName missed check-in #$checkInNumber at $missedTime';
      
      if (mounted) {
        setState(() {
          _lastMissedCheckInAlert = missedCheckinInfo;
        });

        // Show the missed check-in notification
        await NotificationService.showMissedCheckInNotification(
          userName: userName,
          checkInNumber: checkInNumber,
          missedTime: missedTime,
          userLocation: currentLocation,
        );

        // Hide banner after 12 seconds
        Future.delayed(const Duration(seconds: 12)).then((_) {
          if (mounted) setState(() => _lastMissedCheckInAlert = null);
        });

        debugPrint('✅ Missed check-in notification displayed for $userName');
      }
    } catch (e) {
      debugPrint('❌ Error showing missed check-in from Firebase: $e');
    }
  }

  String _formatMalaysianAddress(Map<String, dynamic>? address, String fallback) {
    if (address == null || address.isEmpty) return _cleanDisplayName(fallback);
    List<String> parts = [];
    try {
      void addIfValid(String? value) { if (value != null && value.isNotEmpty && value.trim().isNotEmpty) parts.add(value.trim()); }
      addIfValid(address['shop']?.toString());
      addIfValid(address['amenity']?.toString());
      addIfValid(address['building']?.toString());
      addIfValid(address['tourism']?.toString());
      addIfValid(address['road']?.toString());
      if (parts.isEmpty || !parts.any((p) => p.toLowerCase().contains('jalan') || p.toLowerCase().contains('road'))) addIfValid(address['pedestrian']?.toString());
      addIfValid(address['suburb']?.toString());
      if (parts.length < 3) { addIfValid(address['neighbourhood']?.toString()); addIfValid(address['quarter']?.toString()); }
      addIfValid(address['city']?.toString());
      if (parts.length < 4) addIfValid(address['town']?.toString());
      addIfValid(address['state']?.toString());
      if (parts.length < 5) addIfValid(address['postcode']?.toString());
      if (parts.length >= 2 && parts.length <= 6) {
        List<String> limitedParts = parts.take(4).toList();
        return limitedParts.join(', ');
      } else if (parts.length == 1) {
        return parts[0];
      } else {
        return _cleanDisplayName(fallback);
      }
    } catch (e) {
      return _cleanDisplayName(fallback);
    }
  }

  String _cleanDisplayName(String displayName) {
    try {
      if (displayName.isEmpty) return 'Unknown location';
      String cleaned = displayName.replaceAll(RegExp(r'\d+,\s*'), '');
      cleaned = cleaned.trim();
      if (cleaned.length > 80) cleaned = '${cleaned.substring(0, 80)}...';
      return cleaned.isEmpty ? 'Unknown location' : cleaned;
    } catch (e) {
      return 'Unknown location';
    }
  }




  void _hideOverlay() { _overlayEntry?.remove(); _overlayEntry = null; }



  Future<void> getAddress(double lat, double lon) async {
    debugPrint('getAddress called for: $lat, $lon');
    
    // Validate coordinates
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      debugPrint('Invalid coordinates: lat=$lat, lon=$lon');
      if (mounted) {
        setState(() {
          currentAddress = 'Invalid location coordinates';
        });
      }
      return;
    }
    
    // Rate limiting: ensure at least 1 second between requests
    if (_lastNominatimRequest != null) {
      final timeSinceLastRequest = DateTime.now().difference(_lastNominatimRequest!);
      if (timeSinceLastRequest < _nominatimDelay) {
        debugPrint('Rate limiting: waiting ${(_nominatimDelay - timeSinceLastRequest).inMilliseconds}ms');
        await Future.delayed(_nominatimDelay - timeSinceLastRequest);
      }
    }
    _lastNominatimRequest = DateTime.now();
    
    try {
      final url = 'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json&addressdetails=1';
      debugPrint('Making API request to: $url');
      final resp = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'SafeGoEmergencyApp/1.0 (contact@safego.app)',
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://safego.app'
      });
      if (resp.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(resp.body);
        String address = data['display_name']?.toString() ?? '';
        debugPrint('Raw address from API: $address');
        
        if (data['address'] != null && data['address'] is Map<String, dynamic>) {
          address = _formatMalaysianAddress(data['address'] as Map<String, dynamic>, address);
          debugPrint('Formatted address: $address');
        }
        
        final finalAddress = address.isNotEmpty ? address : 'Current Location';
        debugPrint('Setting currentAddress to: $finalAddress');
        
        if (mounted) setState(() { currentAddress = finalAddress; });
        return;
      } else if (resp.statusCode == 403) {
        debugPrint('Nominatim API access forbidden (403). Using fallback address.');
        if (mounted) setState(() { currentAddress = 'Location: ${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}'; });
        return;
      } else {
        debugPrint('Nominatim API error: ${resp.statusCode}');
      }
    } catch (e) {
      // ignore and fallthrough to generic location message
    }
    if (mounted) setState(() { currentAddress = 'Location unavailable - please refresh'; });
  }

  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error(
          'Location permissions are permanently denied, we cannot request permissions.');
    }

  final pos = await Geolocator.getCurrentPosition(
    desiredAccuracy: LocationAccuracy.best);

    setState(() {
      currentLocation = ll.LatLng(pos.latitude, pos.longitude);
      // Set immediate coordinate fallback while waiting for address lookup
      currentAddress = 'Lat: ${pos.latitude.toStringAsFixed(4)}, Lng: ${pos.longitude.toStringAsFixed(4)}';
    });

    try {
      mapController.move(ll.LatLng(pos.latitude, pos.longitude), 15.0);
      debugPrint('Calling getAddress for: ${pos.latitude}, ${pos.longitude}');
      
      // Validate coordinates before calling getAddress
      if (pos.latitude.isFinite && pos.longitude.isFinite && 
          pos.latitude.abs() <= 90 && pos.longitude.abs() <= 180) {
        await getAddress(pos.latitude, pos.longitude);
      } else {
        debugPrint('Invalid position coordinates: lat=${pos.latitude}, lon=${pos.longitude}');
        setState(() {
          currentAddress = 'Invalid GPS coordinates received';
        });
      }
    } catch (e) {
      debugPrint('Error in _getCurrentLocation: $e');
      if (mounted) {
        setState(() {
          currentAddress = 'Location: ${pos.latitude.toStringAsFixed(4)}, ${pos.longitude.toStringAsFixed(4)}';
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
        title: Text('Welcome $_userName!'),
        elevation: 4,
        shadowColor: Colors.black54,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            tooltip: 'My FCM Profile',
            icon: const Icon(Icons.person, color: Colors.black),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const MyProfilePage(),
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout, color: Colors.black),
            onPressed: () async {
              // Sign out the current user and navigate to emergency contact sign in page
              try {
                await FirebaseAuth.instance.signOut();
                // Navigate to emergency contact sign in page
                if (mounted) {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const EmergencyContactSignIn(),
                    ),
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sign out failed: $e')));
              }
            },
          ),
        ],
      ),
      // Custom bottom bar: Home icon with label below the icon
      bottomNavigationBar: Container(
        height: 64,
        decoration: BoxDecoration(
          color: const Color.fromARGB(255, 255, 225, 190),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, -1))],
        ),
        child: SafeArea(
          top: false,
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.home, color: Colors.black, size: 28),
                  SizedBox(height: 4),
                  Text('Home', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
/////////////////// Floating action buttons (multiple buttons above live location)//////////////////////////////
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
    ///////// Journey Start button (top)//////////
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.green[400]!, Colors.green[600]!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: FloatingActionButton(
              onPressed: () async {
                try {
                  // Get current user info
                  final user = FirebaseAuth.instance.currentUser;
                  final userName = user?.displayName ?? 'SafeGo User';
                  final startTime = DateTime.now().toString().substring(11, 19); // HH:MM:SS format
                  final destination = "Work"; // You can make this dynamic or get from user input
                  
                  // Show Journey Started notification
                  await NotificationService.showJourneyStartedNotification(
                    userName: userName,
                    destination: destination,
                    startTime: startTime,
                  );
                  
                  // Update the UI to show the journey started banner
                  setState(() {
                    _lastJourneyStartedInfo = '$userName started a journey to $destination at $startTime';
                  });

                  // Hide the banner after 8 seconds
                  Future.delayed(const Duration(seconds: 8)).then((_) {
                    if (mounted) setState(() => _lastJourneyStartedInfo = null);
                  });
                  
                  // Also show a snackbar for immediate feedback
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('🚗 Journey Started'),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 3),
                    ),
                  );
                } catch (e) {
                  // Fallback to snackbar if notification fails
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Failed to start journey notification'),
                      backgroundColor: Colors.red,
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              backgroundColor: Colors.transparent,
              elevation: 0,
              heroTag: "journeyStartButton",
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.directions_car,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(height: 1),
                  const Text(
                    'START',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 7,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6), 
   /////////// Emergency Contact Added button (second)///////////
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.purple[400]!, Colors.purple[600]!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.purple.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: FloatingActionButton(
              onPressed: () async {
                try {
                  // Get current user info
                  final user = FirebaseAuth.instance.currentUser;
                  final userName = user?.displayName ?? 'SafeGo User';
                  
                  // Show Emergency Contact Added notification using local notification service
                  final FlutterLocalNotificationsPlugin notification = FlutterLocalNotificationsPlugin();
                  
                  final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
                    'contact_added_channel',
                    'Contact Added Notifications',
                    channelDescription: 'Notifications when emergency contacts are added',
                    importance: Importance.high,
                    priority: Priority.high,
                    playSound: true,
                    enableVibration: true,
                    vibrationPattern: Int64List.fromList([0, 400, 200, 400]),
                    ticker: 'SafeGo Emergency Contact Added',
                    icon: '@mipmap/ic_launcher',
                    color: Color(0xFF4CAF50), // Green color for success
                    ledColor: Color(0xFF4CAF50),
                    ledOnMs: 1000,
                    ledOffMs: 500,
                    autoCancel: true,
                    showWhen: true,
                    when: DateTime.now().millisecondsSinceEpoch,
                  );

                  const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
                    presentAlert: true,
                    presentBadge: true,
                    presentSound: true,
                    sound: 'default',
                    categoryIdentifier: 'contact_added_category',
                    threadIdentifier: 'safego_contact_added',
                    interruptionLevel: InterruptionLevel.active,
                  );

                  final NotificationDetails platformChannelSpecifics = NotificationDetails(
                    android: androidDetails,
                    iOS: iosDetails,
                  );

                  await notification.show(
                    55555, // Unique ID for contact added notifications
                    'Emergency Contact Added ✅',
                    '$userName has added you to their emergency contacts!',
                    platformChannelSpecifics,
                    payload: 'contact_added',
                  );
                  
                  // Also show a snackbar for immediate feedback
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('✅ $userName has added you to their emergency contacts!'),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 4),
                    ),
                  );
                } catch (e) {
                  // Fallback to snackbar if notification fails
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Failed to show contact added notification'),
                      backgroundColor: Colors.red,
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              backgroundColor: Colors.transparent,
              elevation: 0,
              heroTag: "contactAddedButton",
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.person_add,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(height: 1),
                  const Text(
                    'ADDED',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 6,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8), 
    ////////// Safe Arrival button (third)/////////
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.teal[400]!, Colors.teal[600]!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.teal.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: FloatingActionButton(
              onPressed: () async {
                try {
                  // Get current user info
                  final user = FirebaseAuth.instance.currentUser;
                  final userName = user?.displayName ?? 'SafeGo User';
                  final arrivalTime = DateTime.now().toString().substring(11, 19); // HH:MM:SS format
                  
                  // Show Safe Arrival notification
                  await NotificationService.showArrivalNotification(
                    userName: userName,
                    arrivalTime: arrivalTime,
                  );
                  
                  // Also show a snackbar for immediate feedback
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('🎉 Journey Complete! Safe arrival confirmed'),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 3),
                    ),
                  );
                } catch (e) {
                  // Fallback to snackbar if notification fails
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Failed to send arrival notification'),
                      backgroundColor: Colors.red,
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              backgroundColor: Colors.transparent,
              elevation: 0,
              heroTag: "arrivalButton",
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.check_circle,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(height: 1),
                  const Text(
                    'ARRIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 7,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10), 
    ////////// Missed Check-in SOS button (third)//////////
          Container(
            width: 65,
            height: 65,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.orange[400]!, Colors.orange[600]!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.orange.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: FloatingActionButton(
              onPressed: () async {
                try {
                  // Get current user info
                  final user = FirebaseAuth.instance.currentUser;
                  final userName = user?.displayName ?? 'SafeGo User';
                  final missedTime = DateTime.now().toString().substring(11, 19); // HH:MM:SS format
                  
                  // Show Missed Check-in SOS notification
                  await NotificationService.showMissedCheckInNotification(
                    userName: userName,
                    checkInNumber: 1, // You can make this dynamic based on actual check-in count
                    missedTime: missedTime,
                    userLocation: currentAddress,
                  );
                  
                  // Also show a snackbar for immediate feedback
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('⚠️ MISSED CHECK-IN SOS ALERT ⚠️'),
                      backgroundColor: Colors.orange,
                      duration: Duration(seconds: 3),
                    ),
                  );
                } catch (e) {
                  // Fallback to dialog if notification fails
                  EmergencyAlert.show(context);
                }
              },
              backgroundColor: Colors.transparent,
              elevation: 0,
              heroTag: "missedCheckinButton",
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.schedule_outlined,
                    color: Colors.white,
                    size: 20,
                  ),
                  const SizedBox(height: 1),
                  const Text(
                    'MISSED',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12), 
    /////////// Emergency SOS button (middle)///////////
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.red[400]!, Colors.red[600]!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: FloatingActionButton(
              onPressed: () async {
                try {
                  // Get current user info
                  final user = FirebaseAuth.instance.currentUser;
                  final userName = user?.displayName ?? 'SafeGo User';
                  final alertTime = DateTime.now().toString().substring(11, 19); // HH:MM:SS format
                  
                  // Show SOS notification
                  await NotificationService.showEmergencySOSNotification(
                    userName: userName,
                    alertTime: alertTime,
                    userLocation: currentAddress,
                  );
                  
                  // Also show a snackbar for immediate feedback
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('🚨 EMERGENCY SOS ACTIVATED 🚨'),
                      backgroundColor: Colors.red,
                      duration: Duration(seconds: 3),
                    ),
                  );
                } catch (e) {
                  // Fallback to dialog if notification fails
                  EmergencyAlert.show(context);
                }
              },
              backgroundColor: Colors.transparent,
              elevation: 0,
              heroTag: "emergencySOSButton",
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.warning,
                    color: Colors.white,
                    size: 24,
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'SOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16), 
      //////////// Main floating action button for live location///////////
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.blue[400]!, Colors.blue[600]!],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withOpacity(0.3),
                  blurRadius: 15,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: FloatingActionButton(
              onPressed: () {
                // Navigate to live location page
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const live.HomePage(),
                  ),
                );
              },
              backgroundColor: Colors.transparent,
              elevation: 0,
              heroTag: "liveLocationButton",
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.location_on,
                    color: Colors.white,
                    size: 28,
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
///////////////////// End of floating action buttons //////////////////////////////
      
      
      // SOS button removed per user request
      body: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[
          // Top info panel
          Container(
            width: double.infinity,
            constraints: BoxConstraints(minHeight: 85),
            decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 2))]),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your current location', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.normal, fontSize: 13)),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(Icons.location_on, color: Colors.red, size: 18),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          currentAddress, 
                          style: TextStyle(fontSize: 13, color: Colors.black, fontWeight: FontWeight.bold), 
                          maxLines: 2, 
                          overflow: TextOverflow.ellipsis
                        )
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ),

            // Small banner when a contact is recently added in safego
            if (_lastContactAddedName != null)
              Container(
                width: double.infinity,
                color: const Color.fromARGB(255, 233, 245, 233),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.person_add, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(child: Text('New emergency contact added: ' + (_lastContactAddedName ?? ''), style: const TextStyle(fontWeight: FontWeight.w600))),
                  ],
                ),
              ),

            // Small banner when a journey is started in safego
            if (_lastJourneyStartedInfo != null)
              Container(
                width: double.infinity,
                color: const Color.fromARGB(255, 230, 240, 255),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.directions_car, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '🚗 Journey Started: ' + (_lastJourneyStartedInfo ?? ''),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.blue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Emergency SOS alert banner
            if (_lastEmergencyAlert != null)
              Container(
                width: double.infinity,
                color: const Color.fromARGB(255, 255, 235, 235),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.red, size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _lastEmergencyAlert ?? '',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Missed check-in alert banner
            if (_lastMissedCheckInAlert != null)
              Container(
                width: double.infinity,
                color: const Color.fromARGB(255, 255, 243, 224),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.schedule_outlined, color: Colors.orange, size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _lastMissedCheckInAlert ?? '',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Map area using flutter_map
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: mapController,
                  options: MapOptions(
                    initialCenter: currentLocation ?? ll.LatLng(3.1390, 101.6869),
                    initialZoom: 13.0,
                    onLongPress: (tapPosition, point) {
                      _onMapLongPress(point);
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                      subdomains: const ['a', 'b', 'c'],
                    ),
                    if (currentLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            width: 80,
                            height: 80,
                            point: currentLocation!,
                            child: const Icon(Icons.my_location, color: Colors.blue, size: 36),
                          ),
                        ],
                      ),
                  ],
                ),
                if (isLoading)
                  Container(color: Colors.black.withOpacity(0.3), child: const Center(child: CircularProgressIndicator())),
                // Refresh location button
                Positioned(
                  top: 16,
                  right: 16,
                  child: FloatingActionButton(
                    mini: true,
                    onPressed: _getCurrentLocation,
                    backgroundColor: Colors.white,
                    heroTag: "locationRefreshButton", // Unique hero tag
                    child: const Icon(Icons.my_location, color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    for (final sub in _safegoWatcherSubs) {
      try {
        sub.cancel();
      } catch (_) {}
    }
    _journeyNotificationSubscription?.cancel();
    _emergencyNotificationSubscription?.cancel();
    destinationController.dispose();
    location1Controller.dispose();
    location2Controller.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    _hideOverlay();
    super.dispose();
  }
}
