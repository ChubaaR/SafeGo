import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'auth_service.dart';
import 'notification_service.dart';

class JourneyCheckIn {
  static Timer? _globalTimer;
  static int _globalSecondsRemaining = 15; // 10 seconds countdown
  static DateTime? _timerStartTime;
  static bool _isTimerRunning = false;
  static VoidCallback? _onTimerExpired;
  
  // Start the global timer before showing dialog (called when check-in interval is reached) //int duration = 15 sec countdown
  static void startGlobalTimer({int duration = 15, VoidCallback? onExpired}) {
    if (_isTimerRunning) {
      debugPrint('Global check-in timer already running');
      return;
    }
    
    _globalSecondsRemaining = duration;
    _timerStartTime = DateTime.now();
    _isTimerRunning = true;
    _onTimerExpired = onExpired;
    
    debugPrint('Starting global check-in timer: ${_globalSecondsRemaining} seconds');
    
    _globalTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      _globalSecondsRemaining--;
      debugPrint('Global check-in timer: ${_globalSecondsRemaining} seconds remaining');
      
      if (_globalSecondsRemaining <= 0) {
        debugPrint('Global check-in timer expired - triggering SOS callback');
        stopGlobalTimer();
        
        // Trigger the SOS callback if provided
        if (_onTimerExpired != null) {
          _onTimerExpired!();
        }
      }
    });
  }
  
  // Stop the global timer
  static void stopGlobalTimer() {
    _globalTimer?.cancel();
    _globalTimer = null;
    _isTimerRunning = false;
    _onTimerExpired = null;
    debugPrint('Global check-in timer stopped');
  }
  
  // Get remaining time for dialog display
  static int get remainingSeconds => _globalSecondsRemaining;
  static bool get isExpired => _globalSecondsRemaining <= 0;
  
  static Future<bool> show(BuildContext context, int checkInNumber, int totalJourneyMinutes, DateTime journeyStartTime) async {
    // Calculate how much time is left when dialog is shown
    int dialogSecondsRemaining = _globalSecondsRemaining;
    
    if (_timerStartTime != null) {
      final elapsed = DateTime.now().difference(_timerStartTime!).inSeconds;
      dialogSecondsRemaining = math.max(0, 15 - elapsed);
      debugPrint('Dialog shown ${elapsed} seconds after timer start, ${dialogSecondsRemaining} seconds remaining');
    }
    
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false, // Prevent dismissing by tapping outside
      builder: (BuildContext context) {
        return _JourneyCheckInDialog(
          checkInNumber: checkInNumber,
          totalJourneyMinutes: totalJourneyMinutes,
          journeyStartTime: journeyStartTime,
          initialSecondsRemaining: dialogSecondsRemaining,
        );
      },
    );
    
    // Stop the global timer when dialog closes (whether successful or not)
    stopGlobalTimer();
    
    return result ?? false;
  }
}

class _JourneyCheckInDialog extends StatefulWidget {
  final int checkInNumber;
  final int totalJourneyMinutes;
  final int initialSecondsRemaining;
  final DateTime journeyStartTime;

  const _JourneyCheckInDialog({
    required this.checkInNumber,
    required this.totalJourneyMinutes,
    required this.journeyStartTime,
    this.initialSecondsRemaining = 10, 
  });

  @override
  _JourneyCheckInDialogState createState() => _JourneyCheckInDialogState();
}

class _JourneyCheckInDialogState extends State<_JourneyCheckInDialog> with WidgetsBindingObserver {
  Timer? _timer;
  int _secondsRemaining = 10; // Will be set from initialSecondsRemaining 
  final AuthService _authService = AuthService();
  bool _isAuthenticating = false;
  bool _appInBackground = false;
  DateTime? _backgroundTimestamp;
  Timer? _backgroundTimer;
  bool _backgroundSOSTriggered = false;

  @override
  void initState() {
    super.initState();
    
    // Initialize with the time remaining from global timer
    _secondsRemaining = widget.initialSecondsRemaining;
    debugPrint('Check-in dialog initialized with ${_secondsRemaining} seconds remaining');
    
    // If global timer expired before dialog was shown, trigger SOS immediately
    if (JourneyCheckIn.isExpired) {
      debugPrint('Global timer already expired - triggering immediate SOS');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context).pop(false);
        _showTimeoutSOS();
      });
      return;
    }
    
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
    _startAutoBiometricAuthentication();
    _scheduleBackgroundSOS();
  }

  Future<void> _startAutoBiometricAuthentication() async {
    // Start biometric authentication automatically after a brief delay
    await Future.delayed(const Duration(milliseconds: 30));
    if (mounted) {
      _authenticateUser();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App going to background - timer continues running
        _appInBackground = true;
        _backgroundTimestamp = DateTime.now();
        debugPrint('Check-in dialog: App went to background at $_backgroundTimestamp (${_secondsRemaining}s remaining)');
        debugPrint('Timer will continue running in background');
        break;
        
      case AppLifecycleState.resumed:
        // App coming back from background
        debugPrint('Check-in dialog: App resumed (${_secondsRemaining}s remaining, SOS triggered: $_backgroundSOSTriggered)');
        
        if (_appInBackground && _backgroundTimestamp != null) {
          final backgroundDuration = DateTime.now().difference(_backgroundTimestamp!);
          debugPrint('Was in background for ${backgroundDuration.inSeconds} seconds');
          
          // Check if SOS was triggered while in background
          if (_backgroundSOSTriggered && mounted) {
            debugPrint('SOS was triggered while in background - showing SOS dialog now');
            _showTimeoutSOS();
          } else if (_secondsRemaining <= 0 && mounted) {
            // Timer expired while in background but SOS wasn't triggered yet
            debugPrint('Timer expired in background - triggering SOS now');
            Navigator.of(context).pop(false);
            _showTimeoutSOS();
          } else if (mounted) {
            // Update UI to reflect current timer state
            setState(() {
              // Refresh UI with current timer value
            });
          }
        }
        
        _appInBackground = false;
        _backgroundTimestamp = null;
        break;
        
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        debugPrint('Check-in dialog: App detached/hidden');
        break;
    }
  }

  void _scheduleBackgroundSOS() {
    // Schedule a backup SOS trigger as a safety net
    // This runs parallel to the main timer for extra reliability
    _backgroundTimer = Timer(Duration(seconds: _secondsRemaining + 2), () {
      if (!_backgroundSOSTriggered) {
        _backgroundSOSTriggered = true;
        debugPrint('Backup SOS timer triggered for check-in ${widget.checkInNumber}');
        debugPrint('Main timer may have been affected by system - triggering backup SOS');
        _sendBackgroundSOSNotification();
        
        // If app is in foreground and dialog still mounted, trigger SOS
        if (mounted && !_appInBackground) {
          Navigator.of(context).pop(false);
          _showTimeoutSOS();
        }
      }
    });
  }

  Future<void> _sendBackgroundSOSNotification() async {
    try {
      // This method is called by backup timer for logging purposes
      // The actual SOS notification will be sent by _showTimeoutSOS() when appropriate
      debugPrint('Backup timer triggered - SOS would be sent if needed for check-in ${widget.checkInNumber}');
      
      // Send missed check-in notification
      await _sendMissedCheckInNotification();
    } catch (e) {
      debugPrint('Error in background SOS handler: $e');
    }
  }

  Future<void> _sendMissedCheckInNotification() async {
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
      
      // Get current location with address conversion (same as SOS button)
      try {
        Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
        );
        
        // Set coordinates as fallback first
        String coordinates = '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}';
        userLocation = coordinates;
        
        // Try multiple fast methods to get human-readable address
        await _getFastReadableAddress(position.latitude, position.longitude).then((address) {
          if (address != null && address.isNotEmpty && address != coordinates) {
            userLocation = address;
            debugPrint('✅ Check-in got fast readable address: $userLocation');
          } else {
            debugPrint('⚠️ Check-in: Fast address conversion failed, using coordinates');
          }
        }).catchError((error) {
          debugPrint('⚠️ Check-in: Error in fast address conversion: $error');
        });
        
      } catch (e) {
        debugPrint('Error getting location for missed check-in notification: $e');
        userLocation = 'Location unavailable';
      }
      
      // Format missed time
      final now = DateTime.now();
      final missedTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      
      // Send missed check-in push notification
      await NotificationService.showMissedCheckInNotification(
        userName: userName,
        checkInNumber: widget.checkInNumber,
        missedTime: missedTime,
        userLocation: userLocation,
      );
      
      debugPrint('Missed check-in notification sent for $userName (check-in #${widget.checkInNumber}) at $missedTime');
      
    } catch (e) {
      debugPrint('Error sending missed check-in notification: $e');
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
  _backgroundTimer?.cancel(); // Cancel background monitoring
  _backgroundSOSTriggered = false; // Ensure no pending SOS triggers after successful authentication
        JourneyCheckIn.stopGlobalTimer(); // Stop the global timer
        
        // Cancel the SOS timer for this check-in notification
        NotificationService.cancelCheckInSOSByCheckInNumber(widget.checkInNumber, widget.journeyStartTime);
        
        // Cancel the scheduled SOS notification
        NotificationService.cancelScheduledSOSNotification(widget.checkInNumber, widget.journeyStartTime);
        
        debugPrint('Check-in ${widget.checkInNumber} authenticated successfully - all timers and scheduled SOS cancelled');
        Navigator.of(context).pop(true); // Return true for successful authentication
        
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Check-in ${widget.checkInNumber} completed successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
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
      // Sync with global timer instead of counting down independently
      _secondsRemaining = JourneyCheckIn.remainingSeconds;
      debugPrint('Check-in timer: ${_secondsRemaining} seconds remaining (app background: $_appInBackground)');
      
      if (_secondsRemaining <= 0 || JourneyCheckIn.isExpired) {
        _timer?.cancel();
        _backgroundTimer?.cancel(); // Cancel background monitoring
        debugPrint('Check-in timer expired - triggering SOS (app background: $_appInBackground)');
        
        if (mounted && !_appInBackground) {
          // App is in foreground - show UI immediately
          setState(() {
            _secondsRemaining = 0;
          });
          Navigator.of(context).pop(false); // Return false to indicate timeout/failure
          _showTimeoutSOS();
        } else {
          // App is in background - mark SOS as triggered for when app resumes
          _backgroundSOSTriggered = true;
          debugPrint('Timer expired while app in background - SOS will trigger on resume');
          
          // Still try to trigger SOS if possible (for when app comes back)
          if (mounted) {
            Navigator.of(context).pop(false);
            _showTimeoutSOS();
          }
        }
      } else if (mounted && !_appInBackground) {
        // Only update UI if app is in foreground to avoid unnecessary setState calls
        setState(() {
          // Timer tick - update UI with synced time
        });
      }
    });
  }

  void _showTimeoutSOS() {
    if (!mounted) return;
    
    // Send missed check-in notification when SOS timeout occurs
    _sendMissedCheckInNotification();
    
    // Note: SOS alert notification is already scheduled to appear automatically in background
    // We only need to show the dialog here when user opens the app after timeout
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false, // Prevent dismissing without biometric verification
        onPopInvokedWithResult: (didPop, result) async {
          if (!didPop) {
            // User tried to exit - require biometric authentication
            bool isAuthenticated = await _authService.authenticateWithBiometrics();
            if (isAuthenticated && context.mounted) {
              debugPrint('SOS alert cancelled - user authenticated successfully');
              
              // Cancel SOS alert notification
              NotificationService.cancelSOSAlertNotification();
              
              // Cancel any scheduled SOS notifications for this check-in
              NotificationService.cancelScheduledSOSNotification(widget.checkInNumber, widget.journeyStartTime);
              
              Navigator.of(context).pop(); // Close SOS dialog
              
              // Show confirmation message
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('SOS alert cancelled. Journey continues with regular check-ins for your safety.'),
                  backgroundColor: Colors.green,
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
                // User confirmed they are safe - close SOS dialog
                debugPrint('SOS alert cancelled - user confirmed safety, journey continues');
                
                // Cancel SOS alert notification
                NotificationService.cancelSOSAlertNotification();
                
                // Cancel any scheduled SOS notifications for this check-in
                NotificationService.cancelScheduledSOSNotification(widget.checkInNumber, widget.journeyStartTime);
                
                Navigator.of(context).pop(); // Close SOS dialog
                
                // Show confirmation message
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('SOS alert cancelled. Journey continues with regular check-ins for your safety.'),
                    backgroundColor: Colors.green,
                    duration: Duration(seconds: 3),
                  ),
                );
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
        ),
      ),
    );
  }


  @override
  void dispose() {
    _timer?.cancel();
    _backgroundTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
            // Custom AppBar for the popup (following sos.dart design pattern)
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
                title: Text(
                  'Journey Check-in ${widget.checkInNumber}',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _authenticateUser,
                ), // The X button (similar to sos.dart)
                centerTitle: true,
              ),
            ),
            // Content section (following sos.dart design pattern)
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                children: [
                  const Text(
                    'Scan Your Face/Fingerprint',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  // Biometrics images (following sos.dart design pattern)
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
                  // Timer display (following sos.dart design pattern)
                  Column(
                    children: [
                      Text(
                        'Time remaining to complete check-in:',
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

  // Fast address conversion with timeout and comprehensive address building (identical to notification service)
  Future<String?> _getFastReadableAddress(double lat, double lon) async {
    try {
      debugPrint('🔍 Fast geocoding for coordinates: $lat, $lon');
      
      // Use Flutter's built-in geocoding with timeout for speed
      final future = placemarkFromCoordinates(lat, lon);
      final placemarks = await future.timeout(
        const Duration(seconds: 3), // Fast timeout
        onTimeout: () {
          debugPrint('⏰ Fast geocoding timeout after 3 seconds');
          return <Placemark>[];
        },
      );
      
      debugPrint('📋 Fast geocoding returned ${placemarks.length} placemarks');
      
      if (placemarks.isNotEmpty) {
        final placemark = placemarks.first;
        
        debugPrint('🏠 Fast geocoding placemark details:');
        debugPrint('   Street: ${placemark.street}');
        debugPrint('   SubLocality: ${placemark.subLocality}');
        debugPrint('   Locality: ${placemark.locality}');
        debugPrint('   SubAdministrativeArea: ${placemark.subAdministrativeArea}');
        debugPrint('   AdministrativeArea: ${placemark.administrativeArea}');
        debugPrint('   PostalCode: ${placemark.postalCode}');
        debugPrint('   Country: ${placemark.country}');
        debugPrint('   IsoCountryCode: ${placemark.isoCountryCode}');
        
        // Build a readable location string with comprehensive address components (duplicate-safe)
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
          debugPrint('🚀 Fast geocoding success: $readableLocation');
          return readableLocation;
        }
      }
      
      debugPrint('⚠️ Fast geocoding returned no usable address parts');
      return null;
      
    } catch (e) {
      debugPrint('❌ Fast geocoding error: $e');
      return null;
    }
  }
}

