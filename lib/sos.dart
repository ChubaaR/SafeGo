import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'auth_service.dart';
import 'notification_service.dart';

class EmergencyAlert {
  static Future<void> show(BuildContext context) async {
    return showDialog(
      context: context,
      barrierDismissible: false, // Prevent dismissing by tapping outside
      builder: (BuildContext context) {
        return _EmergencyDialog();
      },
    );
  }
}

class _EmergencyDialog extends StatefulWidget {
  @override
  _EmergencyDialogState createState() => _EmergencyDialogState();
}

class _EmergencyDialogState extends State<_EmergencyDialog> {
  Timer? _timer;
  int _secondsRemaining = 15; /// 15 second countdown for SOS alert
  final AuthService _authService = AuthService();
  String _userName = 'User';
  String? _userLocation;

  @override
  void initState() {
    super.initState();
    _getUserInfo();
    _getCurrentLocation();
    _startTimer();
    _startAutoBiometricAuthentication();
  }

  // Get user information from Firebase
  Future<void> _getUserInfo() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        
        if (userDoc.exists && mounted) {
          setState(() {
            _userName = userDoc.data()?['name'] ?? user.displayName ?? 'User';
          });
        }
      }
    } catch (e) {
      debugPrint('Error getting user info: $e');
    }
  }

  // Get current location and convert to address
  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _userLocation = 'Location services disabled';
          });
        }
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            setState(() {
              _userLocation = 'Location permission denied';
            });
          }
          return;
        }
      }

      Position position = await Geolocator.getCurrentPosition();
      
      // First set coordinates as fallback
      String coordinates = '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}';
      
      if (mounted) {
        setState(() {
          _userLocation = coordinates; // Set coordinates first as fallback
        });
      }
      
      // Try to get human-readable address
      String address = await _getAddressFromCoordinates(position.latitude, position.longitude);
      
      if (mounted) {
        setState(() {
          _userLocation = address;
        });
      }
    } catch (e) {
      debugPrint('Error getting location: $e');
      if (mounted) {
        setState(() {
          _userLocation = 'Location unavailable';
        });
      }
    }
  }

  // Convert coordinates to readable address
  Future<String> _getAddressFromCoordinates(double lat, double lon) async {
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
        return _trimAddress(fullAddress);
      } else {
        // Fallback to coordinates if geocoding fails
        return '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';
      }
    } catch (e) {
      debugPrint('Error getting address: $e');
      // Fallback to coordinates if geocoding fails
      return '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';
    }
  }

  // Trim long addresses to keep them concise
  String _trimAddress(String address) {
    // Split by commas and take the first few meaningful parts
    List<String> parts = address.split(', ');
    
    if (parts.length <= 3) {
      return address; // Already short enough
    }
    
    // Take first 3 parts (usually street, area, city)
    String trimmed = parts.take(3).join(', ');
    
    // If still too long, truncate and add ellipsis
    if (trimmed.length > 50) {
      trimmed = '${trimmed.substring(0, 47)}...';
    }
    
    return trimmed;
  }

  // Send SOS push notification
  Future<void> _sendSOSNotification() async {
    try {
      // Format current time
      final now = DateTime.now();
      final formattedTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      
      // Send emergency SOS notification to connected devices via FCM
      await NotificationService.sendSOSAlertFCM(
        userName: _userName,
        alertTime: formattedTime,
        currentLocation: _userLocation,
        additionalMessage: 'Emergency assistance needed immediately!',
      );
      
      // Also show local notification as backup
      await NotificationService.showEmergencySOSNotification(
        userName: _userName,
        alertTime: formattedTime,
        userLocation: _userLocation,
      );
      
      debugPrint('SOS notification sent for $_userName at $formattedTime');
    } catch (e) {
      debugPrint('Error sending SOS notification: $e');
    }
  }



  Future<void> _startAutoBiometricAuthentication() async {
    // Start biometric authentication automatically after a brief delay
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      _cancelWithBiometrics();
    }
  }

  Future<void> _cancelWithBiometrics() async {
    bool isAuthenticated = await _authService.authenticateWithBiometrics();
    if (mounted) {
      if (isAuthenticated) {
        _timer?.cancel();
        
        debugPrint('SOS alert cancelled - user authenticated successfully');
        
        Navigator.of(context).pop();
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => PopScope(
            canPop: false, // Prevent unauthorized dismissal of safety confirmation
            onPopInvoked: (didPop) {
              if (!didPop) {
                // For the "I'm Safe" confirmation, we can allow dismissal since the SOS was already cancelled
                // But we'll just dismiss it normally - no additional biometrics needed for this confirmation
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
                  child: Text(
                    'Emergency alert cancelled successfully!',
                    style: const TextStyle(fontSize: 16),
                    textAlign: TextAlign.center,
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
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            ), // Close Dialog
          ), // Close PopScope
        );
      } else {
        // Authentication failed - stay in the authentication popup
        // Don't close the dialog, just show a message or retry
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Authentication failed. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 2),
          ),
        );
        // Optionally, you could retry authentication after a delay
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) {
          _cancelWithBiometrics(); // Retry authentication
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
          
          // Emergency alert triggered when timer reaches 0
          debugPrint('Emergency SOS alert triggered for user: $_userName at location: $_userLocation');
          
          // Send push notification when SOS is activated
          _sendSOSNotification();
          
          // Auto-send alert when timer reaches 0
          Navigator.of(context).pop();
            showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => PopScope(
              canPop: false, // Prevent unauthorized exit from SOS alert dialog
              onPopInvoked: (didPop) async {
                if (!didPop) {
                  // Handle swipe/back gesture attempts - require biometric verification
                  bool isAuthenticated = await _authService.authenticateWithBiometrics();
                  if (isAuthenticated) {
                    // User confirmed they are safe
                    debugPrint('SOS alert cancelled via swipe/back - user confirmed safety');
                    Navigator.of(context).pop();
                  } else {
                    // Authentication failed - show message and keep dialog open
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Authentication failed. Cannot dismiss SOS alert.'),
                        backgroundColor: Colors.red,
                        duration: Duration(seconds: 3),
                      ),
                    );
                  }
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
                  color: Colors.red,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                  ),
                ),
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  automaticallyImplyLeading: false,
                  toolbarHeight: 80,
                  title: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.warning,
                        color: Colors.black,
                        size: 40,
                      ),
                      Text(
                        'SOS ALERT',
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  centerTitle: true,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    Text(
                      'SOS ALERT HAS BEEN SENT!\n\nYour emergency contacts have been notified and help is on the way. Stay calm and stay safe!',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'If this was a false alert, please verify your biometric immediately to cancel the emergency response!',
                      style: const TextStyle(fontSize: 16, color: Colors.black, fontWeight: FontWeight.bold),
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
                onPressed: () async {
                    bool isAuthenticated = await _authService.authenticateWithBiometrics();
                    if (isAuthenticated) {
                      // User confirmed they are safe
                      debugPrint('SOS alert cancelled - user confirmed safety');
                      Navigator.of(context).pop();
                    } else if (mounted) {
                      // Authentication failed or was cancelled
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Authentication failed. Please try again.'),
                          backgroundColor: Colors.red,
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                },
                child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              ],
            ),
            ), // Close Dialog
            ), // Close PopScope
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose(); // Cancel timer when dialog is disposed
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Prevent back button from closing without authentication
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _cancelWithBiometrics();
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
                  'Authentication',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _cancelWithBiometrics,
                ), //////The X button
                centerTitle: true,
              ),
            ),
            // Content section
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: [
                  const Text(
                    'Authenticating with Biometrics...',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  // Biometrics images (face and fingerprint) - Auto authentication in progress
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
                          const Text(
                            'Auto authenticating...',
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
                          const Text(
                            'Auto authenticating...',
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
                  // Timer row with boxed containers
                  Column(
                    children: [
                      Text(
                        'To avoid accidental alerts, verify in',
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
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}