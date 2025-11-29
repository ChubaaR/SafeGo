import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:safego/app_nav_key.dart';

class FirebaseMessagingService {
  static final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Initialize Firebase Messaging
  static Future<void> initialize() async {
    print('[FCM] Initializing Firebase Messaging');
    
    // Request permission
    NotificationSettings settings = await _messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    print('[FCM] Permission status: ${settings.authorizationStatus}');

    // Get FCM token
    String? token = await _messaging.getToken();
    if (token != null) {
      print('[FCM] Device token: $token');
      await _saveTokenToFirestore(token);
    }

    // Listen for token refresh
    _messaging.onTokenRefresh.listen(_saveTokenToFirestore);

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // Handle notification when app is opened from background
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // Handle notification when app is opened from terminated state
    RemoteMessage? initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      _handleMessageOpenedApp(initialMessage);
    }
  }

  // Save FCM token to Firestore (both user-specific and global collections)
  static Future<void> _saveTokenToFirestore(String token) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        print('[FCM] No user logged in, skipping token save');
        return;
      }

      print('[FCM] Saving token to Firestore for user: ${user.uid}');

      // Save to user-specific collection (existing functionality)
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

      // ALSO save to global collection for cross-user SOS alerts
      await _firestore
          .collection('fcm_tokens')
          .doc(token)
          .set({
        'token': token,
        'userId': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'platform': Theme.of(appNavigatorKey.currentContext!).platform.toString(),
      });

      print('[FCM] Token saved to both user-specific and global collections');
    } catch (e) {
      print('[FCM] Error saving token: $e');
    }
  }

  // Handle foreground messages (when app is open)
  static void _handleForegroundMessage(RemoteMessage message) {
    print('[FCM] Foreground message received');
    print('[FCM] Title: ${message.notification?.title}');
    print('[FCM] Body: ${message.notification?.body}');
    print('[FCM] Data: ${message.data}');

    final type = message.data['type'] ?? '';
    
    if (type == 'contact_added') {
      final contactName = message.data['contactName'] ?? message.notification?.title ?? '';
      _showSuccessDialog(contactName);
    }
  }

  // Handle message when app is opened from notification
  static void _handleMessageOpenedApp(RemoteMessage message) {
    print('[FCM] App opened from notification');
    print('[FCM] Data: ${message.data}');

    final type = message.data['type'] ?? '';
    
    if (type == 'contact_added') {
      final contactName = message.data['contactName'] ?? '';
      _showSuccessDialog(contactName);
    }
  }

  // Show the success dialog
  static void _showSuccessDialog(String contactName) {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) {
      print('[FCM] No context available to show dialog');
      return;
    }

    print('[FCM] Showing success dialog for: $contactName');

    showDialog(
      context: ctx,
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
                  "Success",
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
                  const Icon(
                    Icons.check_circle,
                    color: Colors.green,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '$contactName has been added to your emergency contacts!',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 12,
                  ),
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: const Text(
                  'OK',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Clean up tokens when user logs out (both collections)
  static Future<void> deleteToken() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      String? token = await _messaging.getToken();
      if (token != null) {
        // Delete from user-specific collection
        await _firestore
            .collection('users')
            .doc(user.uid)
            .collection('fcm_tokens')
            .doc(token)
            .delete();
        
        // Also delete from global collection
        await _firestore
            .collection('fcm_tokens')
            .doc(token)
            .delete();
        
        await _messaging.deleteToken();
        print('[FCM] Token deleted from both collections');
      }
    } catch (e) {
      print('[FCM] Error deleting token: $e');
    }
  }
}

// Background message handler (must be top-level function)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('[FCM] Background message received');
  print('[FCM] Title: ${message.notification?.title}');
  print('[FCM] Body: ${message.notification?.body}');
}
