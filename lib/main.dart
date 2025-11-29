import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:safego/sign_in.dart';
import 'package:safego/notification_service.dart';
import 'splash_screen.dart';
import 'package:flutter_gemini/flutter_gemini.dart';
import 'package:safego/const.dart';
import 'package:safego/app_nav_key.dart';
import 'dart:async';
import 'package:safego/firebase_messaging_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize Firebase
  await Firebase.initializeApp();
  
  // Initialize Firebase Messaging (for push notifications)
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  await FirebaseMessagingService.initialize();
  
  // Initialize notification service
  await NotificationService.initialize();
  
  // Initialize FCM token sharing for emergency contacts
  await NotificationService.initializeFCMTokenSharing();
  // Sends FAQs into Firestore (so that if the FAQ not present so the app can fetch these answers)
  try {
    // Import `cloud_firestore` at top if not already present. (Using a runtime import avoids breaking environments where Firestore)
    final faqsCol = FirebaseFirestore.instance.collection('faqs');
    final snapshot = await faqsCol.limit(1).get();
    if (snapshot.docs.isEmpty) {
      final List<Map<String, String>> seedFaqs = [
        {
          'question': 'What is SafeGo?',
          'answer': 'SafeGo is a personal safety app that helps you share your journey, '
              'manage emergency contacts, and send quick SOS alerts. It also supports '
              'scheduled check-ins so trusted contacts can be notified if you don\'t respond.'
        },
        {
          'question': 'How do I use SOS?',
          'answer': 'To use SOS: tap the large SOS button on the main screens. '
              'Tapping it will trigger an emergency alert that notifies your '
              'configured emergency contacts and (depending on your setup) '
              'sends location information so they can find you. Make sure your '
              'emergency contacts are set up in the Emergency Contacts section.'
        },
        {
          'question': 'What happens when I miss a check-in?',
          'answer': 'If you miss a scheduled check-in, SafeGo\'s notification service '
              'will detect the missed response and notify your emergency contacts. '
              'This lets your trusted contacts know you may need help and provides '
              'them with your last known location if available.'
        },
        {
          'question': 'Does SafeGo work without an internet connection?',
          'answer': 'Some features of SafeGo require an internet connection (for example, '
              'sending SOS alerts to contacts and syncing check-in status via Firebase). '
              'Other features, like viewing locally cached data, may still work offline, '
              'but for full functionality an internet connection is recommended.'
        },
      ];

      for (final faq in seedFaqs) {
        await faqsCol.add(faq);
      }
    }
  } catch (e) {
    print('FAQ seeding skipped or failed: $e');
  }

  Gemini.init(apiKey: geminiApiKey);

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  // Global notification listener subscription
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _globalNotifSub;
  final Set<String> _globalSeenNotifIds = {};
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _attachGlobalNotificationsListener();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _globalNotifSub?.cancel();
    super.dispose();
  }

  void _attachGlobalNotificationsListener() {
    // Listen for auth state changes to attach/detach notification listener
    FirebaseAuth.instance.authStateChanges().listen((user) {
      _globalNotifSub?.cancel();
      _globalSeenNotifIds.clear();
      
      if (user == null) return;

      print('[GLOBAL_NOTIF] Attaching listener for user: ${user.uid}');

      final topCol = FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: user.uid)
          .orderBy('createdAt', descending: true)
          .limit(20);

      bool isFirstSnapshot = true;

      _globalNotifSub = topCol.snapshots().listen((snapshot) {
        print('[GLOBAL_NOTIF] Snapshot received - isFirst: $isFirstSnapshot, changes: ${snapshot.docChanges.length}');
        
        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final doc = change.doc;
            final id = doc.id;
            final data = doc.data();
            if (data == null) continue;
            
            final type = data['type']?.toString() ?? '';
            final name = (data['relatedContactName']?.toString() ?? '');
            
            print('[GLOBAL_NOTIF] Change detected - ID: $id, Type: $type, Name: $name, isFirst: $isFirstSnapshot');
            
            // Skip if already seen
            if (_globalSeenNotifIds.contains(id)) {
              print('[GLOBAL_NOTIF] Skipping - already seen: $id');
              continue;
            }
            
            // Mark as seen
            _globalSeenNotifIds.add(id);
            
            // On first snapshot, skip all existing notifications (All new notifications after this will be shown)
            if (isFirstSnapshot) {
              print('[GLOBAL_NOTIF] First snapshot - marking as seen but not showing: $id');
              continue;
            }
            
            // This is a new notification that comes after listener started (Device B)
            print('[GLOBAL_NOTIF] New notification detected - showing dialog for: $name');
            
            if (type == 'contact_added') {
              // Show dialog for contact added
              final ctx = appNavigatorKey.currentContext;
              if (ctx != null) {
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
                                '$name has been added to your emergency contacts!',
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
              } else {
                print('[GLOBAL_NOTIF] ERROR: appNavigatorKey.currentContext is null!');
              }
            }
          }
        }
        
        // After processing first snapshot, mark the flag as false
        if (isFirstSnapshot) {
          isFirstSnapshot = false;
          print('[GLOBAL_NOTIF] First snapshot processed - now listening for new notifications');
        }
      }, onError: (e) {
        print('[GLOBAL_NOTIF] Listener error: $e');
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    if (state == AppLifecycleState.resumed) {
      // App has resumed (check for any pending notifications)
      NotificationService.checkOnAppResume();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      home: SplashScreen(
        image: const AssetImage('assets/Homepage.png'),
        duration: const Duration(seconds: 5), // show splash screen for 5 secs
        nextScreen: const SignIn(), // Go directly to sign-in page after splash
      ),
    );
  }
/////////////// end of _MyAppState /////////////
}


