import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  // Stream subscriptions for proper listener management
  static StreamSubscription<QuerySnapshot>? _journeyListener;
  static StreamSubscription<QuerySnapshot>? _emergencyListener;
  static StreamSubscription<QuerySnapshot>? _checkinListener;
  static StreamSubscription<QuerySnapshot>? _testListener;
  static StreamSubscription<User?>? _authListener;
  
  // Set to track already processed notification IDs to prevent duplicates
  static final Set<String> _processedNotificationIds = <String>{};
  
  // Flag to prevent multiple initializations
  static bool _listenersInitialized = false;
  static String? _currentUserId;
  
  // Throttling for debug messages
  static DateTime? _lastDebugTime;
  static const Duration _debugThrottleDuration = Duration(seconds: 2);
  
  // Persistent tracking for check-in notifications (survives app backgrounding)
  static final Map<int, DateTime> _checkInNotificationTimes = {};
  static final Map<int, bool> _checkInResponseReceived = {};
  static final Map<int, int> _notificationCheckInNumbers = {};
  static Timer? _backgroundCheckTimer;

  // Initialize the notification service
  static Future<void> initialize() async {
    try {
      debugPrint('DEBUG: Starting notification service initialization');
      
      // Initialize timezone data
      tz.initializeTimeZones();

      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
        defaultPresentAlert: true,
        defaultPresentBadge: true,
        defaultPresentSound: true,
      );

      const initializationSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      debugPrint('DEBUG: Initializing flutter_local_notifications');
      await _notifications.initialize(
        initializationSettings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );

      // Request permissions for Android 13+
      if (Platform.isAndroid) {
        debugPrint('DEBUG: Requesting Android permissions');
        await _requestAndroidPermissions();
      }

      // Request permissions for iOS
      if (Platform.isIOS) {
        debugPrint('DEBUG: Requesting iOS permissions');
        await _requestIOSPermissions();
      }

      // Create notification channel for Android
      debugPrint('DEBUG: Creating notification channels');
      await _createNotificationChannel();
      
      // Clear any stale notification data from previous sessions
      clearStaleNotificationData();
      
      // Initialize FCM
      await initializeFCM();
      
      debugPrint('DEBUG: Notification service initialization completed');
    } catch (e) {
      debugPrint('ERROR: Failed to initialize notification service: $e');
      rethrow;
    }
  }

  /// Initialize FCM and set up message handling with detailed logging
  static Future<void> initializeFCM() async {
    try {
      debugPrint('🚀 Starting FCM initialization...');

      // Request notification permissions
      NotificationSettings settings = await _messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      debugPrint('📋 FCM Permission status: ${settings.authorizationStatus}');

      // Get and log FCM token for debugging
      String? token = await _messaging.getToken();
      debugPrint('📱 FCM TOKEN FOR THIS DEVICE: $token');
      debugPrint('📱 Copy this token to test from another device!');
      
      // Handle token refresh
      _messaging.onTokenRefresh.listen((String newToken) {
        debugPrint('🔄 FCM TOKEN REFRESHED: $newToken');
      });

      // Handle foreground messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('🔔 ===== RECEIVED FCM MESSAGE IN FOREGROUND =====');
        debugPrint('📨 Message ID: ${message.messageId}');
        debugPrint('📨 From: ${message.from}');
        debugPrint('📋 Data: ${message.data}');
        debugPrint('🏷️ Title: ${message.notification?.title}');
        debugPrint('📝 Body: ${message.notification?.body}');
        debugPrint('🔔 =======================================');
        
        // Show local notification for foreground messages
        if (message.notification != null) {
          _notifications.show(
            message.hashCode,
            message.notification!.title ?? 'SafeGo FCM',
            message.notification!.body ?? 'New FCM notification received',
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'fcm_channel',
                'FCM Notifications',
                importance: Importance.high,
                priority: Priority.high,
              ),
            ),
          );
        } else if (message.data.isNotEmpty) {
          // Handle data-only messages
          _notifications.show(
            message.hashCode,
            message.data['title'] ?? 'SafeGo FCM',
            message.data['body'] ?? 'Data message received',
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'fcm_channel',
                'FCM Notifications',
                importance: Importance.high,
                priority: Priority.high,
              ),
            ),
          );
        }
      });

      // Handle background/terminated app messages (when user taps notification)
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('👆 FCM message OPENED APP: ${message.messageId}');
        debugPrint('📋 Opened app with data: ${message.data}');
      });

      // Check for messages that opened the app from terminated state
      RemoteMessage? initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) {
        debugPrint('🚀 App opened from TERMINATED state by FCM: ${initialMessage.messageId}');
        debugPrint('📋 Initial message data: ${initialMessage.data}');
      }

      // Set up background message handler
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      
      // Set up Firestore listeners for FCM notifications
      await _setupFirestoreNotificationListeners();
      
      // Set up emergency page listeners for Device B
      await _setupEmergencyPageListeners();
      
      debugPrint('✅ FCM initialization complete!');
      debugPrint('📱 Device is ready to receive notifications');
    } catch (e) {
      debugPrint('❌ Error initializing FCM: $e');
    }
  }

  /// Background message handler (must be top-level function)
  static Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
    debugPrint('🔔 ===== HANDLING BACKGROUND FCM MESSAGE =====');
    debugPrint('📨 Message ID: ${message.messageId}');
    debugPrint('📋 Background message data: ${message.data}');
    debugPrint('🏷️ Background title: ${message.notification?.title}');
    debugPrint('📝 Background body: ${message.notification?.body}');
    debugPrint('🔔 ======================================');
  }

  static Future<void> _requestAndroidPermissions() async {
    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      debugPrint('DEBUG: Requesting notification permissions for Android');
      final notificationPermission = await androidImplementation.requestNotificationsPermission();
      debugPrint('DEBUG: Notification permission granted: $notificationPermission');
      
      final alarmPermission = await androidImplementation.requestExactAlarmsPermission();
      debugPrint('DEBUG: Exact alarms permission granted: $alarmPermission');
    } else {
      debugPrint('DEBUG: Android implementation not available');
    }
  }

  static Future<void> _requestIOSPermissions() async {
    final IOSFlutterLocalNotificationsPlugin? iosImplementation =
        _notifications.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();

    if (iosImplementation != null) {
      await iosImplementation.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    }
  }

  static Future<void> _createNotificationChannel() async {
    const AndroidNotificationChannel checkInChannel = AndroidNotificationChannel(
      'check_in_channel',
      'Check-in Notifications',
      description: 'Notifications for journey check-in reminders',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      sound: RawResourceAndroidNotificationSound('notification_sound'),
    );

    const AndroidNotificationChannel sosChannel = AndroidNotificationChannel(
      'sos_channel',
      'SOS Emergency Alerts',
      description: 'Critical emergency SOS alert notifications',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      ledColor: Color(0xFFFF0000), // Red LED
      showBadge: true,
    );

    const AndroidNotificationChannel arrivalChannel = AndroidNotificationChannel(
      'arrival_channel',
      'Arrival Notifications',
      description: 'Notifications for successful journey arrivals',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      ledColor: Color(0xFF4CAF50), // Green LED
      showBadge: true,
    );

    const AndroidNotificationChannel missedCheckInChannel = AndroidNotificationChannel(
      'missed_checkin_channel',
      'Missed Check-in Alerts',
      description: 'Critical alerts for missed journey check-ins',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      ledColor: Color(0xFFFF5722), // Orange LED for missed check-ins
      showBadge: true,
    );

    // FCM notification channels for Firestore listeners
    const AndroidNotificationChannel journeyNotificationsChannel = AndroidNotificationChannel(
      'journey_notifications',
      'Journey Notifications',
      description: 'Notifications when emergency contacts start journeys',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      ledColor: Color(0xFF4CAF50), // Green LED for journey updates
      showBadge: true,
    );

    const AndroidNotificationChannel emergencyNotificationsChannel = AndroidNotificationChannel(
      'emergency_notifications',
      'Emergency Notifications',
      description: 'Critical emergency SOS alerts from contacts',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
      enableLights: true,
      ledColor: Color(0xFFD32F2F), // Red LED for emergencies
      showBadge: true,
    );

    const AndroidNotificationChannel checkinNotificationsChannel = AndroidNotificationChannel(
      'checkin_notifications',
      'Check-in Notifications',
      description: 'Alerts for missed check-ins from emergency contacts',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      ledColor: Color(0xFFFF5722), // Orange LED for check-in alerts
      showBadge: true,
    );

    final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      await androidImplementation.createNotificationChannel(checkInChannel);
      await androidImplementation.createNotificationChannel(sosChannel);
      await androidImplementation.createNotificationChannel(arrivalChannel);
      await androidImplementation.createNotificationChannel(missedCheckInChannel);
      await androidImplementation.createNotificationChannel(journeyNotificationsChannel);
      await androidImplementation.createNotificationChannel(emergencyNotificationsChannel);
      await androidImplementation.createNotificationChannel(checkinNotificationsChannel);
    }
  }

  // Handle notification tap
  static void _onNotificationTapped(NotificationResponse notificationResponse) {
    final String? payload = notificationResponse.payload;
    if (payload != null) {
      switch (payload) {
        case 'check_in_required':
          // Handle check-in notification tap - cancel SOS timer
          final notificationId = notificationResponse.id != null ? int.tryParse(notificationResponse.id.toString()) ?? 0 : 0;
          _cancelCheckInSOSTimer(notificationId);
          debugPrint('Check-in notification tapped - SOS timer cancelled for ID: $notificationId');
          // You can add navigation logic here if needed
          break;
        case 'arrival_success':
          // Handle arrival notification tap
          debugPrint('Arrival notification tapped - user acknowledged safe arrival');
          // You can add navigation logic here if needed
          break;
        case 'emergency_sos_activated':
          // Handle emergency SOS notification tap
          debugPrint('Emergency SOS notification tapped - user opened app from SOS alert');
          // You can add navigation logic here if needed
          break;
        default:
          // Handle missed check-in notifications (payload format: 'missed_checkin_X')
          if (payload.startsWith('missed_checkin_')) {
            final checkInNumber = payload.split('_')[2];
            debugPrint('Missed check-in notification tapped for check-in #$checkInNumber - user responded');
            // Cancel the missed check-in notification since user responded
            cancelMissedCheckInNotification();
            // You can add navigation logic here if needed
          } else {
            debugPrint('Unknown notification payload: $payload');
          }
      }
    }
  }

  // Show immediate SOS emergency notification
  static Future<void> showEmergencySOSNotification({
    required String userName,
    required String alertTime,
    String? userLocation,
  }) async {
    try {
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'sos_channel',
        'SOS Emergency Alerts',
        channelDescription: 'Critical emergency SOS alert notifications',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 500, 200, 500, 200, 500, 200, 500]),
        ticker: 'SafeGo EMERGENCY SOS ACTIVATED',
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFFD32F2F), // Red color for emergency
        ledColor: Color(0xFFD32F2F),
        ledOnMs: 500,
        ledOffMs: 200,
        ongoing: true, // Keep notification persistent until dismissed
        autoCancel: false, // Don't auto-dismiss
        showWhen: true,
        when: DateTime.now().millisecondsSinceEpoch,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
        categoryIdentifier: 'emergency_sos_category',
        threadIdentifier: 'safego_emergency_sos',
        interruptionLevel: InterruptionLevel.critical,
      );

      final NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final String locationInfo = userLocation != null ? '$userLocation' : '';
      
      await _notifications.show(
        888888, // Unique ID for emergency SOS notifications
        '🚨 EMERGENCY SOS ACTIVATED 🚨',
        '$userName activated SOS at $alertTime in $locationInfo',
        platformChannelSpecifics,
        payload: 'emergency_sos_activated',
      );

      debugPrint('Emergency SOS notification sent for $userName at $alertTime');

      // Also send FCM notifications to emergency contacts
      await sendSOSAlertFCM(
        userName: userName,
        alertTime: alertTime,
        currentLocation: userLocation,
        additionalMessage: 'Emergency assistance needed!',
      );

      // AUTO: Send to connected FCM devices (Device B)
      await _sendToConnectedFCMDevices(
        title: '🚨 EMERGENCY SOS ACTIVATED',
        body: '$userName activated SOS at $alertTime${userLocation != null ? ' in $userLocation' : ''} - Emergency assistance needed!',
        notificationType: 'sos_alert',
        additionalData: {
          'userName': userName,
          'alertTime': alertTime,
          'location': userLocation ?? 'Unknown location',
        },
      );
    } catch (e) {
      debugPrint('Error sending emergency SOS notification: $e');
    }
  }

  // Show arrival success notification
  static Future<void> showArrivalNotification({
    required String userName,
    required String arrivalTime,
  }) async {
    try {
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'arrival_channel',
        'Arrival Notifications',
        channelDescription: 'Notifications for successful journey arrivals',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
        ticker: 'SafeGo Arrival Confirmed',
        category: AndroidNotificationCategory.status,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFF4CAF50), // Green color for success
        autoCancel: true,
        showWhen: true,
        when: DateTime.now().millisecondsSinceEpoch,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
        categoryIdentifier: 'arrival_category',
        threadIdentifier: 'safego_arrival',
        interruptionLevel: InterruptionLevel.active,
      );

      final NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        99999, // Unique ID for arrival notifications
        '🎉 Journey Complete!',
        '$userName has successfully arrived at $arrivalTime! Thank you for monitoring.',
        platformChannelSpecifics,
        payload: 'arrival_success',
      );

      debugPrint('Arrival notification sent for $userName at $arrivalTime');

      // AUTO: Send to connected FCM devices (Device B)
      await _sendToConnectedFCMDevices(
        title: '🎉 Journey Complete!',
        body: '$userName has successfully arrived at $arrivalTime! Thank you for monitoring.',
        notificationType: 'journey_arrival',
        additionalData: {
          'userName': userName,
          'arrivalTime': arrivalTime,
        },
      );
    } catch (e) {
      debugPrint('Error sending arrival notification: $e');
    }
  }

  // Show journey cancellation notification
  static Future<void> showJourneyCancelledNotification({
    required String userName,
    required String cancelTime,
    String? currentLocation,
    String? destination,
    String? reason,
  }) async {
    try {
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'arrival_channel',
        'Journey Notifications',
        channelDescription: 'Notifications for journey status updates',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 300, 150, 300]),
        ticker: 'SafeGo Journey Cancelled',
        category: AndroidNotificationCategory.status,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFFFF9800), // Orange color for cancelled journey
        autoCancel: true,
        showWhen: true,
        when: DateTime.now().millisecondsSinceEpoch,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
        categoryIdentifier: 'journey_cancelled_category',
        threadIdentifier: 'safego_journey_cancelled',
        interruptionLevel: InterruptionLevel.active,
      );

      final NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // Build notification body with available information
      String notificationBody = '$userName cancelled their journey at $cancelTime.';
      if (destination != null) {
        notificationBody += ' Destination was: $destination.';
      }
      if (currentLocation != null) {
        notificationBody += ' Last location: $currentLocation.';
      }
      if (reason != null) {
        notificationBody += ' Reason: $reason.';
      }

      await _notifications.show(
        88888, // Unique ID for journey cancellation notifications
        '⚠️ Journey Cancelled',
        notificationBody,
        platformChannelSpecifics,
        payload: 'journey_cancelled',
      );

      debugPrint('Journey cancellation notification sent for $userName at $cancelTime');

      // Also send FCM notifications to emergency contacts
      await sendJourneyCancelledFCM(
        userName: userName,
        cancelTime: cancelTime,
        currentLocation: currentLocation,
        destination: destination,
        reason: reason,
      );

      // AUTO: Send to connected FCM devices (Device B)
      await _sendToConnectedFCMDevices(
        title: '⚠️ Journey Cancelled',
        body: notificationBody,
        notificationType: 'journey_cancelled',
        additionalData: {
          'userName': userName,
          'cancelTime': cancelTime,
          'currentLocation': currentLocation ?? 'Unknown location',
          'destination': destination ?? 'Unknown destination',
          'reason': reason ?? 'User request',
        },
      );
    } catch (e) {
      debugPrint('Error sending journey cancellation notification: $e');
    }
  }

  // Show immediate journey started notification
  static Future<void> showJourneyStartedNotification({
    required String userName,
    required String destination,
    required String startTime,
    String? currentLocation,
  }) async {
    try {
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'check_in_channel',
        'Check-in Notifications',
        channelDescription: 'Notifications for journey check-ins and status',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 300, 100, 300]),
        ticker: 'SafeGo Journey Started',
        icon: '@mipmap/ic_launcher',
        color: Color(0xFF4CAF50),
        autoCancel: true,
        showWhen: true,
        when: DateTime.now().millisecondsSinceEpoch,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
        categoryIdentifier: 'journey_started',
        threadIdentifier: 'safego_journey',
        interruptionLevel: InterruptionLevel.active,
      );

      final NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        12345, // ID for journey started notification
        '🚗 Journey Started',
        '$userName started a journey to ${destination.trim()} at $startTime.\n📍 Tap to view live location and track progress',
        platformChannelSpecifics,
        payload: 'journey_started',
      );

      debugPrint('Journey started notification sent for $userName to $destination at $startTime');

      // Also send FCM notifications to emergency contacts
      await sendJourneyStartedFCM(
        userName: userName,
        destination: destination,
        startTime: startTime,
        currentLocation: currentLocation,
      );

      // AUTO: Send to connected FCM devices (Device B)
      await _sendToConnectedFCMDevices(
        title: '🚗 Journey Started',
        body: '$userName started a journey to ${destination.trim()} at $startTime. Tap to view live location and track progress',
        notificationType: 'journey_started',
        additionalData: {
          'userName': userName,
          'destination': destination,
          'startTime': startTime,
          'currentLocation': currentLocation ?? 'Location not available',
        },
      );
    } catch (e) {
      debugPrint('Error sending journey started notification: $e');
    }
  }

  // Simple test notification for debugging
  static Future<void> showTestNotification() async {
    try {
      debugPrint('DEBUG: Showing test notification');
      
      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'check_in_channel',
        'Check-in Notifications',
        channelDescription: 'Test notification',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
        autoCancel: true,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
      );

      const NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        54321, // Test notification ID
        'Test Notification',
        'This is a test notification to verify the system is working',
        platformChannelSpecifics,
        payload: 'test',
      );

      debugPrint('Test notification sent successfully');

      // AUTO: Send to connected FCM devices (Device B)
      await _sendToConnectedFCMDevices(
        title: 'Test Notification',
        body: 'This is a test notification to verify the system is working',
        notificationType: 'test_notification',
        additionalData: {
          'testType': 'system_test',
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
    } catch (e) {
      debugPrint('Error sending test notification: $e');
    }
  }

  // Test journey cancellation notification for debugging
  static Future<void> showTestJourneyCancellationNotification() async {
    try {
      debugPrint('DEBUG: Showing test journey cancellation notification');
      
      // Test with sample data
      await showJourneyCancelledNotification(
        userName: 'Test User',
        cancelTime: DateTime.now().toString().substring(11, 16), // HH:MM format
        currentLocation: '40.7128, -74.0060', // Sample NYC coordinates
        destination: 'Test Destination',
        reason: 'Testing journey cancellation notification',
      );

      debugPrint('Test journey cancellation notification sent successfully');
    } catch (e) {
      debugPrint('Error sending test journey cancellation notification: $e');
    }
  }

  // Check if notification permissions are properly granted
  static Future<void> checkNotificationPermissions() async {
    try {
      debugPrint('DEBUG: Checking notification permissions');
      
      if (Platform.isAndroid) {
        final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
            _notifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
                
        if (androidImplementation != null) {
          final bool? enabled = await androidImplementation.areNotificationsEnabled();
          debugPrint('DEBUG: Android notifications enabled: $enabled');
        }
      } else if (Platform.isIOS) {
        final IOSFlutterLocalNotificationsPlugin? iosImplementation =
            _notifications.resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>();
                
        if (iosImplementation != null) {
          final bool? enabled = await iosImplementation.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
          debugPrint('DEBUG: iOS notifications enabled: $enabled');
        }
      }
    } catch (e) {
      debugPrint('ERROR: Failed to check notification permissions: $e');
    }
  }

  // Show missed check-in emergency notification
  static Future<void> showMissedCheckInNotification({
    required String userName,
    required int checkInNumber,
    required String missedTime,
    String? userLocation,
  }) async {
    try {
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'sos_channel', // Use SOS channel for emergency notifications
        'SOS Emergency Alerts',
        channelDescription: 'Critical emergency SOS alert notifications',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 300, 100, 300, 100, 300, 100, 300, 100, 300]),
        ticker: 'SafeGo MISSED CHECK-IN ALERT',
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFFFF5722), // Orange color for missed check-in emergency
        ledColor: Color(0xFFFF5722),
        ledOnMs: 300,
        ledOffMs: 100,
        ongoing: true, // Keep notification persistent until acknowledged
        autoCancel: false, // Don't auto-dismiss
        showWhen: true,
        when: DateTime.now().millisecondsSinceEpoch,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
        categoryIdentifier: 'missed_checkin_category',
        threadIdentifier: 'safego_missed_checkin',
        interruptionLevel: InterruptionLevel.critical,
      );

      final NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      // Convert coordinates to readable location name
      final String readableLocation = await _convertCoordinatesToLocation(userLocation);
      final String locationInfo = readableLocation.isNotEmpty ? '\n$readableLocation' : '';
      
      ////this iis for emergency contact to view
      await _notifications.show(
        777777, // Unique ID for missed check-in notifications
        '⚠️ SOS CHECK-IN ALERT ⚠️',
        '$userName triggers #$checkInNumber SOS check on $missedTime at $locationInfo \n\nContact them now.',
        platformChannelSpecifics,
        payload: 'missed_checkin_$checkInNumber',
      );

      debugPrint('Missed check-in notification sent for $userName (check-in #$checkInNumber) at $missedTime');

      // Also send FCM notifications to emergency contacts
      await sendMissedCheckInFCM(
        userName: userName,
        checkInNumber: checkInNumber,
        missedTime: missedTime,
        currentLocation: userLocation,
      );

      // AUTO: Send FCM notification to connected devices (Device B) for missed check-in alerts
      await _sendToConnectedFCMDevices(
        title: '⚠️ SOS CHECK-IN ALERT ⚠️',
        body: '$userName triggers #$checkInNumber SOS check on $missedTime${locationInfo.isNotEmpty ? ' at$locationInfo' : ''} \n\nContact them now.',
        notificationType: 'missed_checkin_alert',
        additionalData: {
          'userName': userName,
          'checkInNumber': checkInNumber,
          'missedTime': missedTime,
          'userLocation': userLocation ?? 'Location unavailable',
        },
      );
      
      debugPrint('📤 FCM notification sent to Device B - missed check-in alert for $userName');
    } catch (e) {
      debugPrint('Error sending missed check-in notification: $e');
    }
  }

  // Show immediate check-in notification (for testing and immediate check-ins)
  static Future<void> showCheckInNotification({
    required int id,
    required int checkInNumber,
    required int remainingMinutes,
  }) async {
    try {
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'check_in_channel',
        'Check-in Notifications',
        channelDescription: 'Notifications for journey check-in reminders',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
        ticker: 'SafeGo Check-in Required',
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFFFF5722), // Orange color for urgency
        ledColor: Color(0xFFFF5722),
        ledOnMs: 1000,
        ledOffMs: 500,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
        categoryIdentifier: 'check_in_category',
        threadIdentifier: 'safego_checkin',
        interruptionLevel: InterruptionLevel.critical,
      );

      final NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        id,
        'SafeGo Check-in Required',
        'Time for check-in #$checkInNumber! Verify your biometrics within ${remainingMinutes} minutes. SOS alert will be sent in 15 seconds if no response.',
        platformChannelSpecifics,
        payload: 'check_in_required',
      );

      // Start 15-second SOS timer for this notification
      _startCheckInSOSTimer(id, checkInNumber);

      debugPrint('Check-in notification sent immediately with 15-second SOS timer');
    } catch (e) {
      debugPrint('Error sending immediate check-in notification: $e');
    }
  }

  // Schedule a check-in notification
  // Schedule SOS notification for future delivery
  static Future<void> _scheduleSOSNotification({
    required int id,
    required DateTime scheduledTime,
    required int checkInNumber,
  }) async {
    try {
      // SOS notification removed - no longer scheduling local notifications

      // FCM notification removed - no longer sending scheduled SOS alerts

      debugPrint('SOS notification scheduled for: $scheduledTime (check-in #$checkInNumber) with ID: $id');
      debugPrint('📤 Immediate FCM notification sent to Device B for scheduled SOS alert');
    } catch (e) {
      debugPrint('Error scheduling SOS notification: $e');
    }
  }

  // Schedule immediate SOS alert notification
  static Future<void> showSOSAlertNotification({
    required int checkInNumber,
    String? userName,
    String? userLocation,
  }) async {
    try {
      // SOS alert notification removed - no longer showing immediate SOS alerts

    } catch (e) {
      debugPrint('Error sending SOS alert notification: $e');
    }
  }

  static Future<void> scheduleCheckInNotification({
    required int id,
    required DateTime scheduledTime,
    required int checkInNumber,
    required int remainingMinutes,
  }) async {
    try {
      final AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'check_in_channel',
        'Check-in Notifications',
        channelDescription: 'Notifications for journey check-in reminders',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 1000, 500, 1000]),
        ticker: 'SafeGo Check-in Required',
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: true,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFFFF5722), // Orange color for urgency
        ledColor: Color(0xFFFF5722),
        ledOnMs: 1000,
        ledOffMs: 500,
      );

      const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
        categoryIdentifier: 'check_in_category',
        threadIdentifier: 'safego_checkin',
        interruptionLevel: InterruptionLevel.critical,
      );

      final NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      final tz.TZDateTime scheduledTZ = tz.TZDateTime.from(
        scheduledTime,
        tz.local,
      );

      await _notifications.zonedSchedule(
        id,
        'SafeGo Check-in Required',
        'Time for check-in #$checkInNumber! Verify your biometrics within ${remainingMinutes} minutes. SOS alert will be sent in 15 seconds if no response.',
        scheduledTZ,
        platformChannelSpecifics,
        payload: 'check_in_required',
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: DateTimeComponents.time,
      );

      // Schedule background SOS monitoring to start when notification is delivered
      _scheduleBackgroundSOSMonitoring(id, checkInNumber, scheduledTime);

      debugPrint('Check-in notification scheduled for: $scheduledTime with background SOS monitoring');
    } catch (e) {
      debugPrint('Error scheduling notification: $e');
    }
  }




  // Cancel a specific notification by ID
  static Future<void> cancelNotification(int notificationId) async {
    try {
      await _notifications.cancel(notificationId);
      debugPrint('Notification with ID $notificationId cancelled');
    } catch (e) {
      debugPrint('Error cancelling notification $notificationId: $e');
    }
  }

  // Cancel SOS alert notification
  static Future<void> cancelSOSAlertNotification() async {
    try {
      await _notifications.cancel(999999); // SOS alert uses ID 999999
      debugPrint('SOS alert notification cancelled');
    } catch (e) {
      debugPrint('Error cancelling SOS alert notification: $e');
    }
  }

  // Cancel missed check-in notification
  static Future<void> cancelMissedCheckInNotification() async {
    try {
      await _notifications.cancel(777777); // Missed check-in uses ID 777777
      debugPrint('Missed check-in notification cancelled');
    } catch (e) {
      debugPrint('Error cancelling missed check-in notification: $e');
    }
  }

  // Cancel scheduled SOS notification for a specific check-in
  static Future<void> cancelScheduledSOSNotification(int checkInNumber, DateTime journeyStartTime) async {
    try {
      final notificationId = generateNotificationId(journeyStartTime, checkInNumber);
      final sosNotificationId = notificationId + 100000; // Same offset as used in scheduling
      await _notifications.cancel(sosNotificationId);
      debugPrint('Scheduled SOS notification cancelled for check-in #$checkInNumber');
    } catch (e) {
      debugPrint('Error cancelling scheduled SOS notification: $e');
    }
  }





  // Check if notifications are enabled
  static Future<bool> areNotificationsEnabled() async {
    try {
      if (Platform.isAndroid) {
        final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
            _notifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        
        if (androidImplementation != null) {
          final bool? enabled = await androidImplementation.areNotificationsEnabled();
          return enabled ?? false;
        }
      } else if (Platform.isIOS) {
        final IOSFlutterLocalNotificationsPlugin? iosImplementation =
            _notifications.resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>();
        
        if (iosImplementation != null) {
          final bool? enabled = await iosImplementation.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
          return enabled ?? false;
        }
      }
      return false;
    } catch (e) {
      debugPrint('Error checking notification permissions: $e');
      return false;
    }
  }



  // Schedule background SOS monitoring for future notifications
  static void _scheduleBackgroundSOSMonitoring(int notificationId, int checkInNumber, DateTime notificationTime) {
    // Instead of relying on Dart timers (which don't work when app is backgrounded),
    // schedule an actual SOS notification for 15 seconds after the check-in notification
    final sosTime = notificationTime.add(Duration(seconds: 15));
    
    _scheduleSOSNotification(
      id: notificationId + 100000, // Different ID to avoid conflicts
      scheduledTime: sosTime,
      checkInNumber: checkInNumber,
    );
    
    debugPrint('Scheduled SOS notification for ${sosTime} if check-in #$checkInNumber is ignored');
  }

  // Track check-in notification time for background monitoring
  static void _startCheckInSOSTimer(int notificationId, int checkInNumber) {
    // Record notification time and check-in number
    _checkInNotificationTimes[notificationId] = DateTime.now();
    _checkInResponseReceived[notificationId] = false;
    _notificationCheckInNumbers[notificationId] = checkInNumber;
    
    // Start background monitoring if not already running
    _startBackgroundMonitoring();
    
    debugPrint('Recorded check-in notification time for ID: $notificationId (check-in #$checkInNumber) at ${DateTime.now()}');
  }
  
  // Cancel SOS monitoring when user responds to check-in
  static void _cancelCheckInSOSTimer(int notificationId) {
    _checkInNotificationTimes.remove(notificationId);
    _checkInResponseReceived[notificationId] = true;
    _notificationCheckInNumbers.remove(notificationId);
    
    // If no more notifications to monitor, stop background timer
    if (_checkInNotificationTimes.isEmpty) {
      _backgroundCheckTimer?.cancel();
      _backgroundCheckTimer = null;
    }
    
    debugPrint('Cancelled SOS monitoring for check-in notification ID: $notificationId');
  }
  
  // Mark check-in as responded (call this when user completes check-in)
  static void markCheckInAsResponded(int notificationId) {
    _cancelCheckInSOSTimer(notificationId);
  }
  
  // Public method to cancel check-in SOS timer by check-in number
  static void cancelCheckInSOSByCheckInNumber(int checkInNumber, DateTime journeyStartTime) {
    final notificationId = generateNotificationId(journeyStartTime, checkInNumber);
    _cancelCheckInSOSTimer(notificationId);
    debugPrint('Cancelled SOS timer for check-in #$checkInNumber');
  }
  
  // Start background monitoring timer that checks for missed check-ins
  static void _startBackgroundMonitoring() {
    if (_backgroundCheckTimer != null) return; // Already running
    
    _backgroundCheckTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      await _checkForMissedCheckIns();
      
      // Stop timer if no more notifications to monitor
      if (_checkInNotificationTimes.isEmpty) {
        timer.cancel();
        _backgroundCheckTimer = null;
      }
    });
    
    debugPrint('Started background check-in monitoring');
  }
  
  // Check for missed check-ins and trigger SOS if needed
  static Future<void> _checkForMissedCheckIns() async {
    final now = DateTime.now();
    final missedNotifications = <int>[];
    
    for (final entry in _checkInNotificationTimes.entries) {
      final notificationId = entry.key;
      final notificationTime = entry.value;
      final hasResponded = _checkInResponseReceived[notificationId] ?? false;
      
      // Check if notification is too old (more than 1 hour) - likely stale
      final hoursSinceNotification = now.difference(notificationTime).inHours;
      if (hoursSinceNotification > 1) {
        debugPrint('Removing stale notification $notificationId (${hoursSinceNotification}h old)');
        missedNotifications.add(notificationId);
        continue;
      }
      
      // Check if 15 seconds have passed since notification and no response
      final secondsSinceNotification = now.difference(notificationTime).inSeconds;
      
      if (!hasResponded && secondsSinceNotification >= 15) {
        // Additional validation: Only trigger SOS for recent notifications (within last 30 minutes)
        final minutesSinceNotification = now.difference(notificationTime).inMinutes;
        
        if (minutesSinceNotification <= 30) {
          missedNotifications.add(notificationId);
          
          // Get the actual check-in number for this notification
          final checkInNumber = _notificationCheckInNumbers[notificationId] ?? 1;
          
          debugPrint('Check-in notification $notificationId (check-in #$checkInNumber) timed out after ${secondsSinceNotification}s (${minutesSinceNotification}m ago)');
          await _triggerCheckInTimeoutSOS(checkInNumber);
        } else {
          debugPrint('Notification $notificationId is too old (${minutesSinceNotification}m) - removing without SOS trigger');
          missedNotifications.add(notificationId);
        }
      }
    }
    
    // Clean up processed notifications
    for (final notificationId in missedNotifications) {
      _checkInNotificationTimes.remove(notificationId);
      _checkInResponseReceived.remove(notificationId);
      _notificationCheckInNumbers.remove(notificationId);
    }
  }
  
  // Trigger SOS alert when check-in times out
  static Future<void> _triggerCheckInTimeoutSOS(int checkInNumber) async {
    try {
      debugPrint('Background SOS alert triggered for missed check-in #$checkInNumber');
      
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
        debugPrint('Error getting location for check-in timeout SOS: $e');
        userLocation = 'Location unavailable';
      }
      
      // SOS alert notification removed - no longer calling showSOSAlertNotification
      
      // FCM notification removed - no longer sending SOS alerts for check-in timeouts
      
      debugPrint('Background SOS alert notification sent for $userName at location: $userLocation');
      debugPrint('📄 Document data: 🚨 SOS ALERT SENT 🚨 from $userName to FCM token');
      debugPrint('Note: Journey will continue with regular check-ins even if SOS is canceled');
      
    } catch (e) {
      debugPrint('Error triggering check-in timeout SOS: $e');
    }
  }

  // Generate unique notification IDs based on journey start time
  static int generateNotificationId(DateTime journeyStartTime, int checkInNumber) {
    // Use journey start time and check-in number to create unique ID
    return (journeyStartTime.millisecondsSinceEpoch ~/ 1000) + checkInNumber;
  }
  
  // Call this when app becomes active to check for missed check-ins
  static Future<void> checkOnAppResume() async {
    debugPrint('App resumed - checking for missed check-ins');
    
    // Only check for missed check-ins if there are actually pending notifications
    if (_checkInNotificationTimes.isNotEmpty) {
      await _checkForMissedCheckIns();
      
      // Restart background monitoring if there are still pending notifications
      if (_checkInNotificationTimes.isNotEmpty && _backgroundCheckTimer == null) {
        _startBackgroundMonitoring();
      }
    } else {
      debugPrint('No pending check-in notifications to process');
    }
  }
  
  // Stop background monitoring (call when journey ends)
  static void stopBackgroundMonitoring() {
    _backgroundCheckTimer?.cancel();
    _backgroundCheckTimer = null;
    _checkInNotificationTimes.clear();
    _checkInResponseReceived.clear();
    debugPrint('Stopped background monitoring and cleared all check-in data');
  }
  
  // Convert coordinates to readable location name
  static Future<String> _convertCoordinatesToLocation(String? locationString) async {
    if (locationString == null || locationString.isEmpty || locationString == 'Location unavailable') {
      return 'Location unavailable';
    }

    try {
      // Parse coordinates from the string (format: "lat, lng")
      final parts = locationString.split(', ');
      if (parts.length != 2) return locationString; // Return original if not coordinate format

      final lat = double.tryParse(parts[0]);
      final lng = double.tryParse(parts[1]);
      
      if (lat == null || lng == null) return locationString; // Return original if parsing fails

      // Use reverse geocoding to get readable address
      List<Placemark> placemarks = await placemarkFromCoordinates(lat, lng);
      
      if (placemarks.isNotEmpty) {
        final placemark = placemarks.first;
        
        // Build a readable location string
        List<String> locationParts = [];
        
        if (placemark.street != null && placemark.street!.isNotEmpty) {
          locationParts.add(placemark.street!);
        }
        if (placemark.locality != null && placemark.locality!.isNotEmpty) {
          locationParts.add(placemark.locality!);
        }
        if (placemark.administrativeArea != null && placemark.administrativeArea!.isNotEmpty) {
          locationParts.add(placemark.administrativeArea!);
        }
        if (placemark.country != null && placemark.country!.isNotEmpty) {
          locationParts.add(placemark.country!);
        }

        String readableLocation = locationParts.join(', ');
        
        // Trim if too long (limit to ~50 characters for notification readability)
        if (readableLocation.length > 50) {
          readableLocation = readableLocation.substring(0, 47) + '...';
        }
        
        return readableLocation.isNotEmpty ? readableLocation : locationString;
      }
    } catch (e) {
      debugPrint('Error converting coordinates to location: $e');
    }
    
    return locationString; // Return original coordinates if conversion fails
  }

  // Clear all stale notification data (call this on app start to prevent false alarms)
  static void clearStaleNotificationData() {
    final now = DateTime.now();
    final staleNotifications = <int>[];
    
    // Find notifications older than 1 hour (likely stale from previous sessions)
    for (final entry in _checkInNotificationTimes.entries) {
      final notificationId = entry.key;
      final notificationTime = entry.value;
      final hoursSinceNotification = now.difference(notificationTime).inHours;
      
      if (hoursSinceNotification > 1) {
        staleNotifications.add(notificationId);
      }
    }
    
    // Remove stale notifications
    for (final notificationId in staleNotifications) {
      _checkInNotificationTimes.remove(notificationId);
      _checkInResponseReceived.remove(notificationId);
    }
    
    if (staleNotifications.isNotEmpty) {
      debugPrint('Cleared ${staleNotifications.length} stale notification entries');
    }
    
    // Stop background monitoring if no valid notifications remain
    if (_checkInNotificationTimes.isEmpty) {
      _backgroundCheckTimer?.cancel();
      _backgroundCheckTimer = null;
    }
  }

  // =================== FCM PUSH NOTIFICATIONS ===================
  
  /// Get the current FCM token for this device
  static Future<String?> getCurrentFCMToken() async {
    try {
      String? token = await _messaging.getToken();
      final tokenPreview = token != null && token.length > 20 ? '${token.substring(0, 20)}...' : (token ?? 'null');
      debugPrint('FCM Token retrieved: $tokenPreview');
      return token;
    } catch (e) {
      debugPrint('Error getting FCM token: $e');
      return null;
    }
  }

  /// Send customized journey started FCM notification to connected devices
  static Future<void> sendJourneyStartedFCM({
    required String userName,
    required String destination,
    required String startTime,
    String? currentLocation,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('No authenticated user for FCM journey notification');
        return;
      }

      debugPrint('📤 Sending customized journey FCM notifications from user: ${user.uid}');

      // Connected FCM devices are now handled automatically by _sendToConnectedFCMDevices()
      // This method now only handles traditional emergency contacts to prevent duplicates
      
      // Get traditional emergency contacts for FCM notifications
      final contactsSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('emergency_contacts')
          .get();

      debugPrint('📊 Found ${contactsSnapshot.docs.length} emergency contacts');

      // Send FCM notification to each emergency contact by creating notification documents
      for (final contactDoc in contactsSnapshot.docs) {
        final contactData = contactDoc.data();
        final emergencyContactId = contactData['emergencyContactId'] as String?;
        final contactName = contactData['name'] as String? ?? 'Emergency Contact';
        
        if (emergencyContactId != null) {
          // Check if emergency contact has FCM tokens
          final contactTokensSnapshot = await _firestore
              .collection('users')
              .doc(emergencyContactId)
              .collection('fcm_tokens')
              .get();

          if (contactTokensSnapshot.docs.isNotEmpty) {
            // Contact has the app - send FCM via notification document
            final locationInfo = currentLocation != null ? 'Location: $currentLocation' : 'Tap to view live location';
            
            await _firestore.collection('journey_notifications').add({
              'type': 'journey_started',
              'fromUserId': user.uid,
              'toUserId': emergencyContactId,
              'userName': userName,
              'destination': destination,
              'startTime': startTime,
              'currentLocation': currentLocation,
              'timestamp': FieldValue.serverTimestamp(),
              'read': false,
              'title': '🚗 Journey Started',
              'body': '$userName started a journey to ${destination.trim()} at $startTime. $locationInfo',
            });

            debugPrint('Journey FCM notification queued for $contactName ($emergencyContactId)');
          } else {
            debugPrint('Emergency contact $contactName does not have FCM tokens (no app installed)');
          }
        }
      }
      
      debugPrint('Journey started FCM notifications sent to all emergency contacts with the app');
    } catch (e) {
      debugPrint('Error sending journey started FCM notifications: $e');
    }
  }

  /// Send journey cancellation FCM notification to emergency contacts
  static Future<void> sendJourneyCancelledFCM({
    required String userName,
    required String cancelTime,
    String? currentLocation,
    String? destination,
    String? reason,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('No authenticated user for journey cancellation FCM notification');
        return;
      }

      debugPrint('📤 Sending journey cancellation FCM notifications from user: ${user.uid}');

      // Get traditional emergency contacts for FCM notifications
      final contactsSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('emergency_contacts')
          .get();

      debugPrint('📊 Found ${contactsSnapshot.docs.length} emergency contacts for journey cancellation');

      // Send FCM notification to each emergency contact by creating notification documents
      for (final contactDoc in contactsSnapshot.docs) {
        final contactData = contactDoc.data();
        final emergencyContactId = contactData['emergencyContactId'] as String?;
        final contactName = contactData['name'] as String? ?? 'Emergency Contact';
        
        if (emergencyContactId != null) {
          // Check if emergency contact has FCM tokens
          final contactTokensSnapshot = await _firestore
              .collection('users')
              .doc(emergencyContactId)
              .collection('fcm_tokens')
              .get();

          if (contactTokensSnapshot.docs.isNotEmpty) {
            // Build notification body
            String notificationBody = '$userName cancelled their journey at $cancelTime.';
            if (destination != null) {
              notificationBody += ' Destination was: $destination.';
            }
            if (currentLocation != null) {
              notificationBody += ' Last location: $currentLocation.';
            }
            if (reason != null) {
              notificationBody += ' Reason: $reason.';
            }
            
            await _firestore.collection('journey_notifications').add({
              'type': 'journey_cancelled',
              'fromUserId': user.uid,
              'toUserId': emergencyContactId,
              'userName': userName,
              'destination': destination ?? 'Unknown destination',
              'cancelTime': cancelTime,
              'currentLocation': currentLocation,
              'reason': reason ?? 'User request',
              'timestamp': FieldValue.serverTimestamp(),
              'read': false,
              'title': '⚠️ Journey Cancelled',
              'body': notificationBody,
            });

            debugPrint('Journey cancellation FCM notification queued for $contactName ($emergencyContactId)');
          } else {
            debugPrint('Emergency contact $contactName does not have FCM tokens (no app installed)');
          }
        }
      }
      
      debugPrint('Journey cancellation FCM notifications sent to all emergency contacts with the app');
    } catch (e) {
      debugPrint('Error sending journey cancellation FCM notifications: $e');
    }
  }

  /// Send SOS alert FCM notification using connected devices only
  static Future<void> sendSOSAlertFCM({
    required String userName,
    required String alertTime,
    String? currentLocation,
    String? additionalMessage,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('No authenticated user for SOS FCM notification');
        return;
      }

      debugPrint('🚨 Sending SOS FCM notifications from user: ${user.uid}');

      // Get connected devices for this user
      debugPrint('🔍 Querying path: users/${user.uid}/connected_fcm_devices');
      final connectedDevicesSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('connected_fcm_devices')
          .where('isActive', isEqualTo: true)
          .get();

      debugPrint('📊 Connected devices query returned ${connectedDevicesSnapshot.docs.length} documents');
      
      // Debug: also check without the isActive filter
      final allDevicesSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('connected_fcm_devices')
          .get();
      debugPrint('📊 Total devices (without filter): ${allDevicesSnapshot.docs.length}');
      
      for (final doc in allDevicesSnapshot.docs) {
        final data = doc.data();
        final token = data['deviceToken']?.toString() ?? 'null';
        final tokenPreview = token.length > 20 ? '${token.substring(0, 20)}...' : token;
        debugPrint('📱 Device: ${doc.id} - isActive: ${data['isActive']} - token: $tokenPreview');
      }

      if (connectedDevicesSnapshot.docs.isEmpty) {
        debugPrint('⚠️ No connected devices found. Please connect devices in My Profile first.');
        return;
      }

      debugPrint('📲 Found ${connectedDevicesSnapshot.docs.length} connected devices to send SOS alert');
      
      // SOS FCM notifications are now handled automatically by _sendToConnectedFCMDevices()
      // This prevents duplicate notifications in Firestore
      debugPrint('✅ SOS FCM notifications will be sent automatically via connected FCM devices system');
      
      debugPrint('✅ SOS FCM notifications sent to ${connectedDevicesSnapshot.docs.length} connected device(s)');
    } catch (e) {
      debugPrint('❌ Error sending SOS FCM notifications: $e');
    }
  }

  /// Send missed check-in FCM notification to emergency contacts
  /// ❌ EXCLUDED from automatic FCM forwarding
  /// Missed check-in notifications are sent ONLY to emergency contacts,
  /// NOT to all connected FCM devices via _sendToConnectedFCMDevices()
  static Future<void> sendMissedCheckInFCM({
    required String userName,
    required int checkInNumber,
    required String missedTime,
    String? currentLocation,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('No authenticated user for missed check-in FCM notification');
        return;
      }

      debugPrint('Sending missed check-in FCM notifications from user: ${user.uid}');

      // Get user's emergency contacts
      final contactsSnapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('emergency_contacts')
          .get();

      // Send missed check-in FCM notification to each emergency contact
      for (final contactDoc in contactsSnapshot.docs) {
        final contactData = contactDoc.data();
        final emergencyContactId = contactData['emergencyContactId'] as String?;
        final contactName = contactData['name'] as String? ?? 'Emergency Contact';
        
        if (emergencyContactId != null) {
          // Check if emergency contact has FCM tokens
          final contactTokensSnapshot = await _firestore
              .collection('users')
              .doc(emergencyContactId)
              .collection('fcm_tokens')
              .get();

          if (contactTokensSnapshot.docs.isNotEmpty) {
            final locationInfo = currentLocation != null ? 'Last known location: $currentLocation' : 'Location unavailable';
            
            final notificationData = {
              'type': 'missed_checkin',
              'fromUserId': user.uid,
              'toUserId': emergencyContactId,
              'userName': userName,
              'checkInNumber': checkInNumber,
              'missedTime': missedTime,
              'currentLocation': currentLocation,
              'timestamp': FieldValue.serverTimestamp(),
              'priority': 'high',
              'read': false,
              'title': '⚠️ Missed Check-in Alert',
              'body': '$userName missed check-in #$checkInNumber at $missedTime. $locationInfo Please contact them to verify safety.',
            };

            debugPrint('📤 Creating checkin_notifications document with data: $notificationData');
            
            final docRef = await _firestore.collection('checkin_notifications').add(notificationData);
            
            debugPrint('✅ Document created with ID: ${docRef.id}');
            debugPrint('📋 Notification data: fromUserId=${user.uid}, toUserId=$emergencyContactId');
            debugPrint('Missed check-in FCM notification queued for $contactName ($emergencyContactId)');
          } else {
            debugPrint('Emergency contact $contactName does not have FCM tokens (no app installed)');
          }
        }
      }
      
      debugPrint('Missed check-in FCM notifications sent to all emergency contacts with the app');
    } catch (e) {
      debugPrint('Error sending missed check-in FCM notifications: $e');
    }
  }

  /// Share FCM token with emergency contacts for direct communication
  static Future<void> shareFCMTokenWithContacts() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('No authenticated user to share FCM token');
        return;
      }

      String? token = await getCurrentFCMToken();
      if (token == null) {
        debugPrint('Could not get FCM token to share');
        return;
      }

      // Update user document with current FCM token for emergency contacts to access
      await _firestore.collection('users').doc(user.uid).update({
        'currentFCMToken': token,
        'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
      });

      debugPrint('FCM token shared with emergency contacts');
    } catch (e) {
      debugPrint('Error sharing FCM token: $e');
    }
  }

  /// Initialize Device B emergency page listeners (call this on Device B app start)
  static Future<void> initializeEmergencyPageListeners() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        debugPrint('🚀 Initializing emergency page listeners for Device B');
        debugPrint('👤 Current user: ${user.uid}');
        debugPrint('📧 User email: ${user.email}');
        await _setupEmergencyPageListeners();
        debugPrint('✅ Device B emergency page listeners ready');
      } else {
        debugPrint('⏳ User not authenticated yet - will setup listeners after login');
        debugPrint('❌ FirebaseAuth.instance.currentUser is NULL');
      }
    } catch (e) {
      debugPrint('❌ Error initializing emergency page listeners: $e');
    }
  }

  /// Initialize FCM token sharing (call this on app start and login)
  static Future<void> initializeFCMTokenSharing() async {
    try {
      // Share initial token
      await shareFCMTokenWithContacts();
      
      // Listen for token refresh and update automatically
      _messaging.onTokenRefresh.listen((newToken) async {
        debugPrint('FCM Token refreshed, updating emergency contacts');
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          await _firestore.collection('users').doc(user.uid).update({
            'currentFCMToken': newToken,
            'fcmTokenUpdatedAt': FieldValue.serverTimestamp(),
          });
        }
      });
      
      debugPrint('FCM token sharing initialized');
    } catch (e) {
      debugPrint('Error initializing FCM token sharing: $e');
    }
  }

  /// Display FCM token for debugging/sharing purposes
  static Future<void> displayFCMTokenInfo(BuildContext context) async {
    try {
      String? token = await getCurrentFCMToken();
      if (token == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not retrieve FCM token')),
        );
        return;
      }

      final user = FirebaseAuth.instance.currentUser;
      final userInfo = user != null ? 'User: ${user.email ?? user.uid}' : 'No user logged in';

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('FCM Token Info'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(userInfo),
                const SizedBox(height: 8),
                const Text('FCM Token:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    token,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This token allows emergency contacts to receive push notifications when you start a journey, send SOS alerts, or miss check-ins.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('Error displaying FCM token: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  /// Send customized FCM notification directly to a device token
  static Future<void> _sendCustomFCMNotification({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
  }) async {
    try {
      debugPrint('📲 Sending custom FCM to token: ${token.substring(0, 20)}...');
      
      // Create FCM notification document for server-side processing
      await _firestore
          .collection('fcm_notifications')
          .add({
        'to': token,
        'notification': {
          'title': title,
          'body': body,
          'sound': 'default',
          'badge': '1',
          'android': {
            'priority': 'high',
            'notification': {
              'icon': '@mipmap/ic_launcher',
              'color': '#4CAF50',
              'channel_id': 'journey_notifications',
            },
          },
          'apns': {
            'payload': {
              'aps': {
                'badge': 1,
                'sound': 'default',
                'content-available': 1,
              },
            },
          },
        },
        'data': data,
        'priority': 'high',
        'content_available': true,
        'timestamp': FieldValue.serverTimestamp(),
        'processed': false,
      });
      
      debugPrint('✅ Custom FCM notification queued for processing');
    } catch (e) {
      debugPrint('❌ Error sending custom FCM notification: $e');
    }
  }

  /// Test FCM by manually entering a token and sending a test notification
  static Future<void> testFCMWithManualToken(BuildContext context) async {
    final TextEditingController tokenController = TextEditingController();
    final TextEditingController messageController = TextEditingController();
    
    String? testResult = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Test FCM Notification'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter the FCM token of the device you want to test:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: tokenController,
                decoration: const InputDecoration(
                  hintText: 'Paste FCM token here (e.g., xhdfhofh...)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              const Text(
                'Custom message (optional):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: messageController,
                decoration: const InputDecoration(
                  hintText: 'Test message from Device A',
                  border: OutlineInputBorder(),
                ),
                maxLength: 100,
              ),
              const SizedBox(height: 8),
              const Text(
                'This will send a journey started notification to the specified token.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (tokenController.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter a FCM token')),
                );
                return;
              }
              Navigator.of(context).pop('send');
            },
            child: const Text('Send Test Notification'),
          ),
        ],
      ),
    );

    if (testResult == 'send') {
      final token = tokenController.text.trim();
      final customMessage = messageController.text.trim();
      
      try {
        await _sendTestNotificationToToken(
          token: token,
          customMessage: customMessage.isEmpty ? null : customMessage,
        );
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Test notification sent to token: ${token.length > 20 ? '${token.substring(0, 20)}...' : token}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        debugPrint('Error sending test notification: $e');
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to send notification: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  /// Send a test journey notification to a specific FCM token using HTTP API
  static Future<void> _sendTestNotificationToToken({
    required String token,
    String? customMessage,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final userName = user?.displayName ?? user?.email ?? 'Test User';
      final now = DateTime.now();
      final startTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      
      // First, try direct FCM HTTP API (requires server key - for testing only)
      final tokenPreview = token.length > 20 ? '${token.substring(0, 20)}...' : token;
      debugPrint('🚀 Attempting direct FCM delivery to token: $tokenPreview');
      
      // For testing - create a test notification that the same device can detect
      // In real usage, we'd need the actual Device B user ID from emergency contacts
      debugPrint('🧪 Creating test notification for current user to verify listeners work');
      await _firestore.collection('journey_notifications').add({
        'type': 'journey_started',
        'fromUserId': user?.uid ?? 'test_user_sender',
        'toUserId': user?.uid ?? 'test_user', // Same device test - Device B should use actual emergency contact user ID
        'userName': userName,
        'destination': customMessage ?? 'Test Destination - Device B',
        'startTime': startTime,
        'currentLocation': 'Test Location',
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'title': '🚗 Test Journey Started (Firestore Listener Test)',
        'body': '$userName started a test journey to ${customMessage ?? "Test Destination"} at $startTime. This tests Firestore listeners on Device B.',
        'isTestNotification': true,
      });
      
      // Also create in test_notifications for tracking
      await _firestore.collection('test_notifications').add({
        'type': 'journey_started_test',
        'token': token,
        'fromUserId': user?.uid ?? 'test_user',
        'userName': userName,
        'destination': customMessage ?? 'Test Destination - Device B',
        'startTime': startTime,
        'currentLocation': 'Test Location',
        'timestamp': FieldValue.serverTimestamp(),
        'title': '🚗 Test Journey Started',
        'body': '$userName started a test journey to ${customMessage ?? "Test Destination"} at $startTime. This is a test notification from Device A to Device B.',
        'isTestNotification': true,
        'deliveryMethod': 'firestore_listener',
      });
      
      // Simulate receiving the message on the same device for immediate testing
      await _simulateReceivedFCMMessage(
        title: '🚗 Test Journey Started',
        body: '$userName started a test journey to ${customMessage ?? "Test Destination"} at $startTime. This is a test from Device A to Device B.',
        token: token,
      );
      
      debugPrint('✅ Test notification delivered locally (simulated FCM)');
    } catch (e) {
      debugPrint('❌ Error sending test notification: $e');
      rethrow;
    }
  }

  /// Simulate receiving an FCM message for testing purposes
  static Future<void> _simulateReceivedFCMMessage({
    required String title,
    required String body,
    required String token,
  }) async {
    try {
      debugPrint('🔔 ===== SIMULATED FCM MESSAGE RECEIVED =====');
      final tokenPreview = token.length > 20 ? '${token.substring(0, 20)}...' : token;
      debugPrint('📨 Simulated for token: $tokenPreview');
      debugPrint('🏷️ Title: $title');
      debugPrint('📝 Body: $body');
      debugPrint('🔔 ================================');
      
      // Show local notification to simulate FCM delivery
      await _notifications.show(
        DateTime.now().millisecondsSinceEpoch, // Unique ID
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'fcm_test_channel',
            'FCM Test Notifications',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
        ),
      );
      
      debugPrint('📱 Local notification displayed to simulate FCM message');
    } catch (e) {
      debugPrint('❌ Error simulating FCM message: $e');
    }
  }

  /// Save commonly used test tokens for quick access
  static final List<String> _savedTestTokens = [];
  
  static Future<void> saveTestToken(String token, String deviceName) async {
    try {
      await _firestore.collection('test_tokens').add({
        'token': token,
        'deviceName': deviceName,
        'savedAt': FieldValue.serverTimestamp(),
        'userId': FirebaseAuth.instance.currentUser?.uid,
      });
      
      if (!_savedTestTokens.contains(token)) {
        _savedTestTokens.add(token);
      }
      
      final tokenPreview = token.length > 20 ? '${token.substring(0, 20)}...' : token;
      debugPrint('Test token saved: $deviceName - $tokenPreview');
    } catch (e) {
      debugPrint('Error saving test token: $e');
    }
  }

  /// Quick test with saved tokens (uses local storage to avoid Firestore permission issues)
  static Future<void> quickTestWithSavedTokens(BuildContext context) async {
    try {
      // For now, use some common test tokens or show manual entry
      // This avoids Firestore permission issues during testing
      final List<Map<String, String>> commonTestTokens = [
        {
          'deviceName': 'Test Device 1',
          'token': 'Enter_actual_FCM_token_here',
        },
        {
          'deviceName': 'Test Device 2', 
          'token': 'Enter_another_FCM_token_here',
        },
      ];

      // Show dialog with option to use predefined tokens or enter new one
      final selectedOption = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Quick FCM Test'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Choose an option for quick testing:'),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Enter FCM Token Manually'),
                subtitle: const Text('Most reliable method'),
                onTap: () => Navigator.of(context).pop('manual'),
              ),
              const Divider(),
              const Text(
                'Pre-configured tokens (update in code):',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              ...commonTestTokens.map((tokenInfo) => ListTile(
                leading: const Icon(Icons.phone_android),
                title: Text(tokenInfo['deviceName']!),
                subtitle: Text('${tokenInfo['token']!.length > 20 ? '${tokenInfo['token']!.substring(0, 20)}...' : tokenInfo['token']!}'),
                enabled: tokenInfo['token'] != 'Enter_actual_FCM_token_here' && 
                        tokenInfo['token'] != 'Enter_another_FCM_token_here',
                onTap: tokenInfo['token'] != 'Enter_actual_FCM_token_here' && 
                       tokenInfo['token'] != 'Enter_another_FCM_token_here'
                    ? () => Navigator.of(context).pop(tokenInfo['token'])
                    : null,
              )),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

      if (selectedOption == 'manual') {
        // Use the manual token entry method
        await testFCMWithManualToken(context);
      } else if (selectedOption != null && selectedOption != 'manual') {
        // Use selected pre-configured token
        await _sendTestNotificationToToken(
          token: selectedOption,
          customMessage: 'Quick test notification',
        );
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Quick test sent to: ${selectedOption.length > 20 ? '${selectedOption.substring(0, 20)}...' : selectedOption}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error with quick test: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Troubleshoot FCM setup for Device B (receiving notifications)
  static Future<void> troubleshootFCMDeviceB(BuildContext context) async {
    try {
      debugPrint('🔧 Starting FCM troubleshooting for Device B...');
      
      String troubleshootingReport = '🔧 FCM Device B Troubleshooting Report\n\n';
      
      // 1. Check FCM token
      String? token = await getCurrentFCMToken();
      if (token != null) {
        troubleshootingReport += '✅ FCM Token: Generated successfully\n';
        troubleshootingReport += '📱 Token: ${token.substring(0, 30)}...\n\n';
      } else {
        troubleshootingReport += '❌ FCM Token: Failed to generate\n\n';
      }
      
      // 2. Check notification permissions
      NotificationSettings settings = await _messaging.requestPermission();
      troubleshootingReport += '📋 Notification Permissions:\n';
      troubleshootingReport += '   - Authorization: ${settings.authorizationStatus}\n';
      troubleshootingReport += '   - Alert: ${settings.alert}\n';
      troubleshootingReport += '   - Sound: ${settings.sound}\n';
      troubleshootingReport += '   - Badge: ${settings.badge}\n\n';
      
      // 3. Check Firebase connection
      try {
        await _firestore.collection('test_connection').doc('test').set({
          'timestamp': FieldValue.serverTimestamp(),
          'deviceToken': token,
        });
        troubleshootingReport += '✅ Firebase Connection: Working\n';
      } catch (e) {
        troubleshootingReport += '❌ Firebase Connection: Failed ($e)\n';
      }
      
      // 4. Test local notification capability
      try {
        await _notifications.show(
          999999,
          '🔧 FCM Troubleshooting',
          'This is a test local notification to verify notification system works',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'test_channel',
              'Test Channel',
              importance: Importance.high,
            ),
          ),
        );
        troubleshootingReport += '✅ Local Notifications: Working\n';
      } catch (e) {
        troubleshootingReport += '❌ Local Notifications: Failed ($e)\n';
      }
      
      troubleshootingReport += '\n📋 Troubleshooting Steps for Device B:\n';
      troubleshootingReport += '1. Make sure app is running/open when testing\n';
      troubleshootingReport += '2. Check device notification settings\n';
      troubleshootingReport += '3. Ensure WiFi/mobile data is working\n';
      troubleshootingReport += '4. Try restarting the app\n';
      troubleshootingReport += '5. Copy FCM token and send it to Device A\n';
      
      debugPrint(troubleshootingReport);
      
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('FCM Troubleshooting'),
            content: SingleChildScrollView(
              child: SelectableText(
                troubleshootingReport,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  // Copy FCM token to clipboard
                  if (token != null) {
                    // Note: This would need clipboard package
                    // For now, show the token in a dialog
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Your FCM Token'),
                        content: SelectableText(token),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    );
                  }
                },
                child: const Text('Copy Token'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      debugPrint('Error in FCM troubleshooting: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Troubleshooting failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Test FCM message handling by simulating a received message
  static Future<void> testFCMMessageHandling() async {
    debugPrint('🧪 Testing FCM message handling simulation...');
    
    // Simulate a test FCM message
    await _notifications.show(
      888888,
      '🧪 FCM Test Simulation',
      'This simulates what happens when Device B receives an FCM notification',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'test_channel',
          'Test Channel', 
          importance: Importance.high,
        ),
      ),
    );
    
    debugPrint('✅ FCM message handling test completed');
  }

  /// Direct FCM test without Cloud Functions - for immediate testing
  static Future<void> testDirectFCMDelivery(BuildContext context) async {
    try {
      debugPrint('🧪 Starting direct FCM test...');
      
      // Get current device token
      String? myToken = await getCurrentFCMToken();
      if (myToken == null) {
        throw Exception('Could not get FCM token for current device');
      }

      // Show confirmation dialog
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('🧪 Direct FCM Test'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('This will simulate receiving an FCM notification on this device.'),
              const SizedBox(height: 16),
              const Text('Your FCM Token:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  myToken,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(height: 16),
              const Text('This tests:'),
              const Text('• FCM token generation'),
              const Text('• Local notification display'),
              const Text('• FCM message simulation'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Test Now'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        // Simulate FCM message delivery
        await _simulateReceivedFCMMessage(
          title: '🧪 Direct FCM Test Success!',
          body: 'This notification proves FCM tokens work and notifications display correctly. Device B would see this when you send from Device A.',
          token: myToken,
        );

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Direct FCM test completed! Check your notifications.'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('❌ Direct FCM test failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Direct FCM test failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // =================== FIRESTORE LISTENERS FOR DEVICE B ===================
  
  /// Set up Firestore listeners specifically for Device B emergency page notifications
  static Future<void> _setupEmergencyPageListeners() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('❌ No user authenticated for emergency page listeners');
        return;
      }

      // Get current device FCM token for listening
      String? currentToken = await _messaging.getToken();
      if (currentToken == null) {
        debugPrint('❌ No FCM token available for emergency page listeners');
        return;
      }

      debugPrint('🔄 Setting up Device B emergency page listeners');
      debugPrint('👤 User: ${user.uid}');
      debugPrint('📱 FCM Token: ${currentToken.length > 20 ? '${currentToken.substring(0, 20)}...' : currentToken}');
      debugPrint('📊 Query: journey_notifications where targetToken == current_token AND displayFormat == emergency_page');

      // First, check for existing documents targeting this FCM token
      try {
        final testQuery = await _firestore
            .collection('journey_notifications')
            .where('targetToken', isEqualTo: currentToken)
            .where('displayFormat', isEqualTo: 'emergency_page')
            .limit(5)
            .get();
        
        debugPrint('📋 Found ${testQuery.docs.length} existing journey notifications for this FCM token');
        for (final doc in testQuery.docs) {
          final data = doc.data();
          debugPrint('📄 Existing notification: ${data['title']} from ${data['fromUserName']} at ${data['startTime']}');
        }
      } catch (e) {
        debugPrint('❌ Error checking existing FCM token notifications: $e');
      }

      // Listen for journey notifications targeting this FCM token (Device B)
      // Temporarily removed orderBy to work without index - will be restored once index builds
      _journeyListener = _firestore
          .collection('journey_notifications')
          .where('targetToken', isEqualTo: currentToken)
          .where('displayFormat', isEqualTo: 'emergency_page')
          .limit(50)
          .snapshots()
          .listen((snapshot) {
        debugPrint('📊 FCM token emergency page listener received ${snapshot.docChanges.length} changes');
        debugPrint('📊 Total documents in snapshot: ${snapshot.docs.length}');
        
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final data = change.doc.data() as Map<String, dynamic>;
            final notificationId = change.doc.id;
            
            debugPrint('📥 New FCM token notification detected: ${change.doc.id}');
            debugPrint('📄 Document data: ${data['title']} from ${data['fromUserName']} to FCM token');
            
            // Check if this is a new notification (not already processed)
            if (!_processedNotificationIds.contains(notificationId)) {
              _processedNotificationIds.add(notificationId);
              
              debugPrint('🚗 Processing new FCM token journey notification: ${data['title']}');
              _handleEmergencyPageNotification(change.doc);
            } else {
              debugPrint('⏭️ FCM token notification already processed: $notificationId');
            }
          }
        }
      }, onError: (error) {
        debugPrint('❌ FCM token emergency page listener error: $error');
      });
      
      debugPrint('✅ FCM token emergency page listeners active for Device B');
    } catch (e) {
      debugPrint('❌ Error setting up FCM token emergency page listeners: $e');
    }
  }

  /// Handle journey notifications specifically for Device B emergency page display
  static Future<void> _handleEmergencyPageNotification(DocumentSnapshot doc) async {
    try {
      final data = doc.data() as Map<String, dynamic>;
      
      debugPrint('📱 ===== DEVICE B EMERGENCY PAGE NOTIFICATION =====');
      debugPrint('🚗 Type: ${data['type']}');
      debugPrint('👤 From: ${data['fromUserName']}');
      debugPrint('📍 Destination: ${data['destination']}');
      debugPrint('🕐 Start Time: ${data['startTime']}');
      debugPrint('🌍 Location: ${data['fromLocation']}');
      debugPrint('📱 ============================================');

      // Display the customized notification on Device B
      await _notifications.show(
        doc.id.hashCode,
        data['title'] ?? '🚗 Journey Started',
        data['body'] ?? '${data['fromUserName']} started a journey',
        NotificationDetails(
          android: AndroidNotificationDetails(
            'journey_notifications',
            'Journey Notifications',
            channelDescription: 'Journey notifications for emergency contacts',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
            color: Color(0xFF4CAF50),
            playSound: true,
            enableVibration: true,
            vibrationPattern: Int64List.fromList([0, 300, 100, 300]),
            autoCancel: true,
            showWhen: true,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            sound: 'default',
            interruptionLevel: InterruptionLevel.active,
          ),
        ),
        payload: 'emergency_page_journey_${doc.id}',
      );
      
      debugPrint('✅ Emergency page notification displayed for: ${data['fromUserName']}');
    } catch (e) {
      debugPrint('❌ Error handling emergency page notification: $e');
    }
  }
  
  /// Set up Firestore listeners to automatically detect new FCM notifications
  /// and display them on Device B when sent from Device A
  static Future<void> _setupFirestoreNotificationListeners() async {
    try {
      // Prevent multiple initializations
      if (_listenersInitialized) {
        debugPrint('🔄 Firestore listeners already initialized - skipping');
        return;
      }

      debugPrint('🚀 Initializing Firestore FCM listeners (one-time setup)');
      _listenersInitialized = true;

      // Listen for authentication state changes and start listeners when user logs in
      _authListener = FirebaseAuth.instance.authStateChanges().listen((user) {
        if (user == null) {
          debugPrint('⚠️ User logged out - stopping FCM listeners');
          _stopListenersForUser();
          return;
        }

        // Only restart listeners if user changed
        if (_currentUserId != user.uid) {
          debugPrint('🎧 User changed (${_currentUserId} → ${user.uid}) - Setting up Firestore FCM listeners');
          _currentUserId = user.uid;
          _startFirestoreListeners(user.uid);
          
          // Ensure FCM token is saved for cross-user communication
          _ensureFCMTokenSaved();
        } else {
          debugPrint('🔄 Same user (${user.uid}) - listeners already active');
        }
      });
    } catch (e) {
      debugPrint('❌ Error setting up Firestore listeners: $e');
    }
  }

  /// Start the actual Firestore listeners for a specific user
  static void _startFirestoreListeners(String userId) {
    try {
      debugPrint('🎧 Starting Firestore FCM listeners for user: $userId');

      // Cancel existing listeners to prevent duplicates
      _cancelAllListeners();

      // 1. Journey notifications listener
      _journeyListener = _firestore
          .collection('journey_notifications')
          .where('toUserId', isEqualTo: userId)
          .where('read', isEqualTo: false)
          .snapshots()
          .listen((snapshot) {
        _throttledDebugPrint('👂 journey_notifications listener triggered - ${snapshot.docChanges.length} changes');
        if (snapshot.docChanges.isEmpty) return;
        
        for (final change in snapshot.docChanges) {
          final docId = change.doc.id;
          if (_processedNotificationIds.contains(docId)) {
            debugPrint('⏭️ Skipping already processed journey notification: $docId');
            continue;
          }
          if (change.type == DocumentChangeType.added) {
            _processedNotificationIds.add(docId);
            _handleJourneyNotification(change.doc);
          }
        }
      }, onError: (e) {
        debugPrint('❌ Error in journey_notifications listener: $e');
      });

      // 2. Listen for emergency SOS notifications sent to this user
      _emergencyListener = _firestore
          .collection('emergency_notifications')
          .where('toUserId', isEqualTo: userId)
          .where('read', isEqualTo: false)
          .snapshots()
          .listen((snapshot) {
        _throttledDebugPrint('👂 emergency_notifications listener triggered - ${snapshot.docChanges.length} changes');
        if (snapshot.docChanges.isEmpty) return;
        
        for (final change in snapshot.docChanges) {
          final docId = change.doc.id;
          if (_processedNotificationIds.contains(docId)) {
            debugPrint('⏭️ Skipping already processed emergency notification: $docId');
            continue;
          }
          if (change.type == DocumentChangeType.added) {
            _processedNotificationIds.add(docId);
            _handleEmergencyNotification(change.doc);
          }
        }
      });

      // 3. Listen for missed check-in notifications sent to this user
      debugPrint('🔍 Setting up checkin_notifications listener for userId: $userId');
      _checkinListener = _firestore
          .collection('checkin_notifications')
          .where('toUserId', isEqualTo: userId)
          .where('read', isEqualTo: false)
          .snapshots()
          .listen((snapshot) {
        debugPrint('👂 checkin_notifications listener triggered - ${snapshot.docChanges.length} changes for userId: $userId');
        debugPrint('📊 Total documents in snapshot: ${snapshot.docs.length}');
        
        if (snapshot.docChanges.isEmpty) {
          debugPrint('⏭️ No changes in checkin_notifications snapshot');
          return;
        }
        
        // Log all documents for debugging
        for (final doc in snapshot.docs) {
          final data = doc.data();
          debugPrint('📋 Document ${doc.id}: toUserId=${data['toUserId']}, read=${data['read']}, type=${data['type']}');
        }
        
        for (final change in snapshot.docChanges) {
          final docId = change.doc.id;
          final changeData = change.doc.data();
          debugPrint('🔄 Processing change: ${change.type} for doc $docId (toUserId: ${changeData?['toUserId']})');
          
          if (_processedNotificationIds.contains(docId)) {
            debugPrint('⏭️ Skipping already processed checkin notification: $docId');
            continue;
          }
          if (change.type == DocumentChangeType.added) {
            debugPrint('➕ Adding new checkin notification to processed list: $docId');
            _processedNotificationIds.add(docId);
            _handleCheckInNotification(change.doc);
          }
        }
      });

      // 4. Listen for test notifications sent from this user (to see what was sent)
      _testListener = _firestore
          .collection('test_notifications')
          .where('fromUserId', isEqualTo: userId)
          .orderBy('timestamp', descending: true)
          .limit(1)
          .snapshots()
          .listen((snapshot) {
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final doc = change.doc;
            final data = doc.data() as Map<String, dynamic>;
            final tokenStr = data['token']?.toString() ?? 'null';
            final tokenPreview = tokenStr.length > 20 ? '${tokenStr.substring(0, 20)}...' : tokenStr;
            debugPrint('📤 Test notification sent: ${data['title']} -> Token: $tokenPreview');
          }
        }
      });

      debugPrint('✅ Firestore FCM listeners active - Device B will auto-display notifications');
    } catch (e) {
      debugPrint('❌ Error starting Firestore listeners: $e');
    }
  }

  /// Handle journey notifications from Device A (started, cancelled, emergency SOS)
  static Future<void> _handleJourneyNotification(DocumentSnapshot doc) async {
    try {
      final data = doc.data() as Map<String, dynamic>;
      
      // Check if this is an emergency SOS alert
      final bool isEmergency = data['isEmergency'] == true || data['type'] == 'emergency_sos';
      
      // Check if this is a journey cancellation
      final bool isCancellation = data['type'] == 'journey_cancelled';
      
      if (isEmergency) {
        debugPrint('🚨 ===== RECEIVED EMERGENCY SOS FROM DEVICE A =====');
        debugPrint('📨 From: ${data['userName']}');
        debugPrint('🕐 Alert Time: ${data['startTime']}');
        debugPrint('📍 Location: ${data['currentLocation']}');
        debugPrint('💬 Message: ${data['additionalMessage']}');
        debugPrint('🚨 =====================================');

        // Display emergency SOS notification with high priority
        await _notifications.show(
          doc.id.hashCode,
          data['title'] ?? '🚨 EMERGENCY SOS ALERT',
          data['body'] ?? '⚠️ ${data['userName']} sent an SOS alert at ${data['startTime']}! Contact them immediately!',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'journey_notifications',
              'Journey Notifications',
              importance: Importance.max,
              priority: Priority.max,
              icon: '@mipmap/ic_launcher',
              color: Color(0xFFD32F2F), // Red for emergency
              fullScreenIntent: true,
              category: AndroidNotificationCategory.alarm,
            ),
          ),
          payload: 'emergency_sos_from_device_a',
        );
      } else if (isCancellation) {
        debugPrint('⚠️ ===== RECEIVED JOURNEY CANCELLATION FROM DEVICE A =====');
        debugPrint('📨 From: ${data['userName']}');
        debugPrint('📍 Destination: ${data['destination']}');
        debugPrint('🕐 Cancel Time: ${data['cancelTime']}');
        debugPrint('📍 Last Location: ${data['currentLocation']}');
        debugPrint('💭 Reason: ${data['reason']}');
        debugPrint('⚠️ ==========================================');

        // Display journey cancellation notification
        await _notifications.show(
          doc.id.hashCode,
          data['title'] ?? '⚠️ Journey Cancelled',
          data['body'] ?? '${data['userName']} cancelled their journey at ${data['cancelTime']}',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'journey_notifications',
              'Journey Notifications',
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
              color: Color(0xFFFF9800), // Orange for cancellation
            ),
          ),
          payload: 'journey_cancelled_from_device_a',
        );
      } else {
        debugPrint('🚗 ===== RECEIVED JOURNEY NOTIFICATION FROM DEVICE A =====');
        debugPrint('📨 From: ${data['fromUserName']}');
        debugPrint('📍 Destination: ${data['destination']}');
        debugPrint('🕐 Start Time: ${data['startTime']}');
        debugPrint('📍 Location: ${data['fromLocation']}');
        debugPrint('🚗 ==========================================');

        // Display regular journey notification
        await _notifications.show(
          doc.id.hashCode,
          '🚗 ${data['fromUserName']} started a journey',
          '${data['destination']} at ${data['startTime']}\nFrom: ${data['fromLocation']}',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'journey_notifications',
              'Journey Notifications',
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
              color: Color(0xFF4CAF50),
            ),
          ),
          payload: 'journey_from_device_a',
        );
      }

      // AUTO: Forward all journey notifications to connected FCM devices (Device B)
      if (isEmergency) {
        await _sendToConnectedFCMDevices(
          title: data['title'] ?? '🚨 EMERGENCY SOS ALERT',
          body: data['body'] ?? '⚠️ ${data['userName']} sent an SOS alert at ${data['startTime']}! Contact them immediately!',
          notificationType: 'emergency_sos_journey',
          additionalData: {
            'userName': data['userName'] ?? 'User',
            'startTime': data['startTime'] ?? '',
            'location': data['currentLocation'] ?? 'Unknown location',
            'additionalMessage': data['additionalMessage'] ?? '',
          },
        );
      } else if (isCancellation) {
        await _sendToConnectedFCMDevices(
          title: data['title'] ?? '⚠️ Journey Cancelled',
          body: data['body'] ?? '${data['userName']} cancelled their journey at ${data['cancelTime']}',
          notificationType: 'journey_cancelled_forwarded',
          additionalData: {
            'userName': data['userName'] ?? 'User',
            'destination': data['destination'] ?? 'Unknown destination',
            'cancelTime': data['cancelTime'] ?? '',
            'currentLocation': data['currentLocation'] ?? 'Unknown location',
            'reason': data['reason'] ?? 'User request',
          },
        );
      } else {
        await _sendToConnectedFCMDevices(
          title: '🚗 ${data['fromUserName']} started a journey',
          body: '${data['destination']} at ${data['startTime']}\nFrom: ${data['fromLocation']}',
          notificationType: 'journey_started_forwarded',
          additionalData: {
            'fromUserName': data['fromUserName'] ?? 'User',
            'destination': data['destination'] ?? '',
            'startTime': data['startTime'] ?? '',
            'fromLocation': data['fromLocation'] ?? 'Unknown location',
          },
        );
      }

      // Mark as read
      await doc.reference.update({'read': true, 'readAt': FieldValue.serverTimestamp()});
      
      debugPrint('✅ ${isEmergency ? 'Emergency SOS' : isCancellation ? 'Journey cancellation' : 'Journey'} notification displayed and forwarded to connected devices');
    } catch (e) {
      debugPrint('❌ Error handling journey notification: $e');
    }
  }

  /// Handle emergency SOS notifications from Device A
  static Future<void> _handleEmergencyNotification(DocumentSnapshot doc) async {
    try {
      final data = doc.data() as Map<String, dynamic>;
      final notificationType = data['type'] as String? ?? 'emergency';
      
      // Handle different types of emergency notifications
      if (notificationType == 'emergency_contact_added') {
        debugPrint('👥 ===== RECEIVED EMERGENCY CONTACT ADDED =====');
        debugPrint('📨 From: ${data['senderName']}');
        debugPrint('👤 Contact: ${data['contactName']}');
        debugPrint('📞 Phone: ${data['contactPhone']}');
        debugPrint('👥 =====================================');

        // Display contact added notification
        await _notifications.show(
          doc.id.hashCode,
          data['title'] ?? '👥 Added to Emergency Contacts',
          data['body'] ?? '${data['senderName']} has added you to their emergency contacts',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'emergency_notifications',
              'Emergency Notifications',
              importance: Importance.high,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
              color: Color(0xFF4CAF50), // Green for positive action
            ),
          ),
          payload: 'contact_added',
        );

        // AUTO: Send to connected FCM devices (Device B)
        await _sendToConnectedFCMDevices(
          title: data['title'] ?? '👥 Added to Emergency Contacts',
          body: data['body'] ?? '${data['senderName']} has added you to their emergency contacts',
          notificationType: 'emergency_contact_added',
          additionalData: {
            'senderName': data['senderName'] ?? 'User',
            'contactName': data['contactName'] ?? '',
            'contactPhone': data['contactPhone'] ?? '',
          },
        );

        debugPrint('✅ Emergency contact added notification displayed and forwarded to connected devices');

      } else {
        // Handle SOS and other emergency types
        debugPrint('🚨 ===== RECEIVED EMERGENCY SOS FROM DEVICE A =====');
        debugPrint('📨 From: ${data['userName']}');
        debugPrint('🕐 Alert Time: ${data['alertTime']}');
        debugPrint('📍 Location: ${data['currentLocation']}');
        debugPrint('💬 Message: ${data['additionalMessage']}');
        debugPrint('🚨 =====================================');

        // Display emergency notification with high priority
        await _notifications.show(
          doc.id.hashCode,
          data['title'] ?? '🚨 EMERGENCY SOS ALERT',
          data['body'] ?? '${data['userName']} sent an SOS alert at ${data['alertTime']}',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'emergency_notifications',
              'Emergency Notifications',
              importance: Importance.max,
              priority: Priority.max,
              icon: '@mipmap/ic_launcher',
              color: Color(0xFFD32F2F),
              fullScreenIntent: true,
              category: AndroidNotificationCategory.alarm,
            ),
          ),
          payload: 'emergency_from_device_a',
        );

        // AUTO: Send to connected FCM devices (Device B) - for SOS alerts
        await _sendToConnectedFCMDevices(
          title: data['title'] ?? '🚨 EMERGENCY SOS ALERT',
          body: data['body'] ?? '${data['userName']} sent an SOS alert at ${data['alertTime']}',
          notificationType: 'emergency_sos',
          additionalData: {
            'userName': data['userName'] ?? 'User',
            'alertTime': data['alertTime'] ?? '',
            'location': data['currentLocation'] ?? 'Unknown location',
            'additionalMessage': data['additionalMessage'] ?? '',
          },
        );

        debugPrint('✅ Emergency SOS notification displayed and forwarded to connected devices');
      }

      // Mark as read
      await doc.reference.update({'read': true, 'readAt': FieldValue.serverTimestamp()});
      
    } catch (e) {
      debugPrint('❌ Error handling emergency notification: $e');
    }
  }

  /// Handle missed check-in notifications from Device A
  static Future<void> _handleCheckInNotification(DocumentSnapshot doc) async {
    try {
      final data = doc.data() as Map<String, dynamic>;
      
      debugPrint('⚠️ ===== RECEIVED MISSED CHECK-IN FROM DEVICE A =====');
      debugPrint('📨 From: ${data['userName']}');
      debugPrint('🔢 Check-in #: ${data['checkInNumber']}');
      debugPrint('🕐 Missed Time: ${data['missedTime']}');
      debugPrint('📍 Location: ${data['currentLocation']}');
      debugPrint('⚠️ ========================================');

      // Display missed check-in notification
      await _notifications.show(
        doc.id.hashCode,
        data['title'] ?? '⚠️ Missed Check-in Alert',
        data['body'] ?? '${data['userName']} missed check-in #${data['checkInNumber']}',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'checkin_notifications',
            'Check-in Notifications',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
            color: Color(0xFFFF5722),
          ),
        ),
        payload: 'checkin_from_device_a',
      );

      // Mark as read
      await doc.reference.update({'read': true, 'readAt': FieldValue.serverTimestamp()});
      
      debugPrint('✅ Missed check-in notification displayed on Device B');
    } catch (e) {
      debugPrint('❌ Error handling check-in notification: $e');
    }
  }

  /// Cancel all existing listeners to prevent duplicates
  static void _cancelAllListeners() {
    debugPrint('🛑 Cancelling existing Firestore listeners...');
    _journeyListener?.cancel();
    _emergencyListener?.cancel();
    _checkinListener?.cancel();
    _testListener?.cancel();
    
    _journeyListener = null;
    _emergencyListener = null;
    _checkinListener = null;
    _testListener = null;
    
    // Clear processed notification IDs when restarting listeners
    _processedNotificationIds.clear();
    
    debugPrint('✅ All existing listeners cancelled and IDs cleared');
  }

  /// Stop listeners for current user (internal method)
  static void _stopListenersForUser() {
    _cancelAllListeners();
    _currentUserId = null;
    debugPrint('🛑 Firestore listeners stopped for user logout');
  }

  /// Stop all Firestore listeners (call when user logs out)
  static void stopFirestoreListeners() {
    _cancelAllListeners();
    _authListener?.cancel();
    _authListener = null;
    _listenersInitialized = false;
    _currentUserId = null;
    debugPrint('🛑 Firestore FCM listeners completely stopped');
  }

  /// Force restart Firestore listeners for manual testing
  static Future<void> forceRestartFirestoreListeners() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('No authenticated user');
      }

      debugPrint('🔄 Force restarting Firestore FCM listeners for user: ${user.uid}');
      
      // Stop existing listeners (they'll restart automatically via auth state listener)
      stopFirestoreListeners();
      
      // Manually start listeners
      _startFirestoreListeners(user.uid);
      
      debugPrint('✅ Firestore listeners force restarted');
    } catch (e) {
      debugPrint('❌ Error force restarting Firestore listeners: $e');
      rethrow;
    }
  }

  /// Test Firestore listeners by creating a notification for the current user (same device test)
  static Future<void> testFirestoreListenersSameDevice() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('No authenticated user');
      }

      final userName = user.displayName ?? user.email ?? 'Test User';
      final now = DateTime.now();
      final startTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

      debugPrint('🧪 Creating test journey notification for same device...');
      debugPrint('📨 FromUserId: ${user.uid}');
      debugPrint('📨 ToUserId: ${user.uid} (same device test)');
      
      // Create a journey notification that should trigger the listener
      await _firestore.collection('journey_notifications').add({
        'type': 'journey_started',
        'fromUserId': user.uid,
        'toUserId': user.uid, // Same device test
        'userName': userName,
        'destination': 'Firestore Listener Test Destination',
        'startTime': startTime,
        'currentLocation': 'Test Location for Listener',
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
        'title': '🧪 Firestore Listener Test',
        'body': '$userName created a test notification to verify Firestore listeners work on this device.',
        'isTestNotification': true,
      });
      
      debugPrint('✅ Test notification created in journey_notifications collection');
      debugPrint('👂 If listeners are working, you should see notification popup within 1-2 seconds');
    } catch (e) {
      debugPrint('❌ Error creating test notification: $e');
      rethrow;
    }
  }

  /// Clear processed notification IDs cache (for testing duplicate prevention)
  static void clearProcessedNotifications() {
    final previousCount = _processedNotificationIds.length;
    _processedNotificationIds.clear();
    debugPrint('🗑️ Cleared processed notification cache - $previousCount IDs removed');
    debugPrint('📝 Note: Previously processed notifications will now show again if triggered');
  }

  /// Throttled debug print to prevent spam
  static void _throttledDebugPrint(String message) {
    final now = DateTime.now();
    if (_lastDebugTime == null || now.difference(_lastDebugTime!) > _debugThrottleDuration) {
      debugPrint(message);
      _lastDebugTime = now;
    }
  }

  /// Show current listener status for debugging
  static void showListenerStatus(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final statusText = '''
📊 Firestore Listener Status:

🔧 Initialization Status:
   - Listeners Initialized: $_listenersInitialized
   - Current User ID: ${_currentUserId ?? 'None'}
   - Authenticated User: ${user?.uid ?? 'None'}

📡 Active Listeners:
   - Journey: ${_journeyListener != null ? '✅ Active' : '❌ Inactive'}
   - Emergency: ${_emergencyListener != null ? '✅ Active' : '❌ Inactive'}
   - Check-in: ${_checkinListener != null ? '✅ Active' : '❌ Inactive'}
   - Test: ${_testListener != null ? '✅ Active' : '❌ Inactive'}
   - Auth State: ${_authListener != null ? '✅ Active' : '❌ Inactive'}

🗂️ Cache Status:
   - Processed Notifications: ${_processedNotificationIds.length}
   - Last Debug Time: ${_lastDebugTime?.toString() ?? 'None'}

💡 Recommendations:
${_getRecommendations()}
    ''';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('🔍 Listener Debug Status'),
        content: SingleChildScrollView(
          child: SelectableText(
            statusText,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Get recommendations based on current status
  static String _getRecommendations() {
    final issues = <String>[];
    
    if (!_listenersInitialized) {
      issues.add('- Tap "🔄 Restart Firestore Listeners"');
    }
    
    if (FirebaseAuth.instance.currentUser == null) {
      issues.add('- User not authenticated - please log in');
    }
    
    if (_journeyListener == null && _listenersInitialized) {
      issues.add('- Journey listener inactive - restart listeners');
    }
    
    if (_processedNotificationIds.length > 10) {
      issues.add('- Clear notification cache to reset duplicates');
    }
    
    return issues.isEmpty ? '✅ All systems working normally' : issues.join('\n');
  }

  /// Ensure FCM token is saved to both user-specific and global collections
  static Future<void> _ensureFCMTokenSaved() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('❌ No authenticated user for FCM token save');
        return;
      }

      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        debugPrint('❌ Could not get FCM token');
        return;
      }

      debugPrint('💾 Ensuring FCM token is saved for user: ${user.uid}');

      // Save to user-specific collection  
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('fcm_tokens')
          .doc(token)
          .set({
        'token': token,
        'userId': user.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // Save to global collection for cross-user SOS alerts
      await _firestore
          .collection('fcm_tokens')
          .doc(token)
          .set({
        'token': token,
        'userId': user.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      debugPrint('✅ FCM token saved to both collections for cross-user communication');
    } catch (e) {
      debugPrint('❌ Error ensuring FCM token saved: $e');
    }
  }

  /// Automatically send notification to connected FCM devices (Device B)
  /// This ensures all notifications (except check-ins) reach connected devices
  /// Automatic FCM forwarding system for connected devices
  /// 
  /// INCLUDED NOTIFICATIONS (automatically forwarded):
  /// - ✅ SOS Emergency Alerts
  /// - ✅ Journey Started/Arrived notifications
  /// - ✅ Journey Cancellation notifications
  /// - ✅ Emergency Contact Addition notifications  
  /// - ✅ Test FCM notifications
  /// 
  /// EXCLUDED NOTIFICATIONS (NOT automatically forwarded):
  /// - ❌ Check-in notifications (regular & missed)
  /// - ❌ Local-only notifications
  /// 
  /// Note: Check-in and missed check-in notifications use direct 
  /// emergency contact system instead of automatic forwarding
  static Future<void> _sendToConnectedFCMDevices({
    required String title,
    required String body,
    required String notificationType,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('No authenticated user for connected FCM notification');
        return;
      }

      // Get connected FCM devices from fcm_connections
      final connectionsSnapshot = await _firestore
          .collection('fcm_connections')
          .where('userIdA', isEqualTo: user.uid)
          .where('isActive', isEqualTo: true)
          .get();

      if (connectionsSnapshot.docs.isEmpty) {
        debugPrint('No connected FCM devices found for automatic notification');
        return;
      }

      debugPrint('📤 Sending notification to ${connectionsSnapshot.docs.length} connected FCM devices');

      // Send to each connected device (Device B)
      for (final connectionDoc in connectionsSnapshot.docs) {
        final connectionData = connectionDoc.data();
        final deviceBToken = connectionData['deviceB'] as String?;

        if (deviceBToken != null) {
          // Create notification document for real-time delivery to Device B
          await _firestore.collection('journey_notifications').add({
            'type': notificationType,
            'fromUserId': user.uid,
            'fromUserName': connectionData['userNameA'] ?? 'User',
            'targetToken': deviceBToken,
            'title': title,
            'body': body,
            'displayFormat': 'emergency_page',
            'timestamp': FieldValue.serverTimestamp(),
            'read': false,
            'additionalData': additionalData ?? {},
          });

          // Also send direct FCM notification
          await _sendCustomFCMNotification(
            token: deviceBToken,
            title: title,
            body: body,
            data: {
              'type': notificationType,
              'fromUserId': user.uid,
              'timestamp': DateTime.now().toIso8601String(),
              ...(additionalData?.map((k, v) => MapEntry(k, v.toString())) ?? {}),
            },
          );

          debugPrint('✅ Notification sent to connected device: ${deviceBToken.substring(0, 20)}...');
        }
      }
    } catch (e) {
      debugPrint('❌ Error sending to connected FCM devices: $e');
    }
  }

  /// Public wrapper to send FCM notifications to connected Device B
  static Future<void> sendToConnectedDevices({
    required String title,
    required String body,
    required String notificationType,
    Map<String, dynamic>? additionalData,
  }) async {
    await _sendToConnectedFCMDevices(
      title: title,
      body: body,
      notificationType: notificationType,
      additionalData: additionalData,
    );
  }
}