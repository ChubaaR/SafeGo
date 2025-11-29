import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../notification_service.dart';

class MyProfilePage extends StatefulWidget {
  const MyProfilePage({Key? key}) : super(key: key);

  @override
  State<MyProfilePage> createState() => _MyProfilePageState();
}

class _MyProfilePageState extends State<MyProfilePage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _deviceBTokenController = TextEditingController();
  
  String? _currentUserToken;
  String? _currentUserId;
  String? _currentUserName;
  List<Map<String, dynamic>> _connectedDevices = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initializeProfile();
  }

  Future<void> _initializeProfile() async {
    setState(() => _isLoading = true);
    
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _currentUserId = user.uid;
      _currentUserName = user.displayName ?? user.email ?? 'Unknown User';
      
      // Get current device FCM token
      _currentUserToken = await FirebaseMessaging.instance.getToken();
      
      // Load connected devices
      await _loadConnectedDevices();
    }
    
    setState(() => _isLoading = false);
  }

  Future<void> _loadConnectedDevices() async {
    if (_currentUserId == null) return;
    
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(_currentUserId!)
          .collection('connected_fcm_devices')
          .get();
      
      _connectedDevices = snapshot.docs.map((doc) {
        final data = doc.data();
        data['docId'] = doc.id;
        return data;
      }).toList();
      
      setState(() {});
    } catch (e) {
      print('Error loading connected devices: $e');
    }
  }

  Future<void> _connectDevice() async {
    if (_deviceBTokenController.text.trim().isEmpty) {
      _showMessage('❌ Please enter Device B FCM token', isError: true);
      return;
    }
    
    if (_currentUserToken == null) {
      _showMessage('❌ Could not get current device token', isError: true);
      return;
    }

    final deviceBToken = _deviceBTokenController.text.trim();
    
    if (deviceBToken == _currentUserToken) {
      _showMessage('❌ Cannot connect to the same device', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Save Device B token in current user's connected devices
      await _firestore
          .collection('users')
          .doc(_currentUserId!)
          .collection('connected_fcm_devices')
          .add({
        'deviceToken': deviceBToken,
        'deviceName': 'Device B',
        'connectedAt': FieldValue.serverTimestamp(),
        'isActive': true,
      });

      // Also save in global connections for bidirectional/ two way communication
      await _firestore.collection('fcm_connections').add({
        'deviceA': _currentUserToken,
        'deviceB': deviceBToken,
        'userIdA': _currentUserId,
        'userNameA': _currentUserName,
        'connectedAt': FieldValue.serverTimestamp(),
        'isActive': true,
      });

      // Send test connection notification to Device B
      await _sendConnectionTestNotification(deviceBToken);

      _deviceBTokenController.clear();
      await _loadConnectedDevices();
      
      _showMessage('✅ Device connected successfully!', isError: false);
    } catch (e) {
      _showMessage('❌ Connection failed: $e', isError: true);
    }

    setState(() => _isLoading = false);
  }

  Future<void> _sendConnectionTestNotification(String targetToken) async {
    try {
      // Create test notification in Firestore
      await _firestore.collection('emergency_notifications').add({
        'type': 'connection_test',
        'fromUserId': _currentUserId,
        'toUserId': 'test_connection',
        'userName': _currentUserName,
        'alertTime': TimeOfDay.now().format(context),
        'currentLocation': 'Device Connection Test',
        'additionalMessage': 'FCM connection established successfully!',
        'timestamp': FieldValue.serverTimestamp(),
        'priority': 'normal',
        'read': false,
        'title': '🔗 FCM Connection Established',
        'body': '✅ $_currentUserName successfully connected to your device! You can now receive emergency notifications.',
        'targetToken': targetToken,
      });

      final tokenPreview = targetToken.length > 20 ? '${targetToken.substring(0, 20)}...' : targetToken;
      print('🔗 Connection test notification sent to: $tokenPreview');
    } catch (e) {
      print('❌ Error sending connection test notification: $e');
    }
  }

  Future<void> _testSOSToConnectedDevices() async {
    if (_connectedDevices.isEmpty) {
      _showMessage('❌ No connected devices found', isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Use the existing SOS FCM method but send to connected devices specifically
      final currentTime = TimeOfDay.now().format(context);
      
      for (final device in _connectedDevices) {
        final deviceToken = device['deviceToken'] as String;
        
        // Create emergency notification for each connected device
        await _firestore.collection('emergency_notifications').add({
          'type': 'sos_alert',
          'fromUserId': _currentUserId,
          'toUserId': 'connected_device',
          'userName': _currentUserName,
          'alertTime': currentTime,
          'currentLocation': 'Test Location - My Profile',
          'additionalMessage': 'TEST SOS: Emergency FCM from My Profile',
          'timestamp': FieldValue.serverTimestamp(),
          'priority': 'critical',
          'read': false,
          'title': '🚨 EMERGENCY SOS ALERT',
          'body': '⚠️ $_currentUserName sent an SOS alert at $currentTime! TEST SOS: Emergency FCM from My Profile Location: Test Location - My Profile Contact them immediately!',
          'targetToken': deviceToken,
        });
      }

      _showMessage('🚨 SOS test sent to ${_connectedDevices.length} connected device(s)!', isError: false);
    } catch (e) {
      _showMessage('❌ SOS test failed: $e', isError: true);
    }

    setState(() => _isLoading = false);
  }

  /// Test journey notification using FCM tokens directly (like testFCMWithManualToken)
  Future<void> _testJourneyNotificationToConnectedDevices() async {
    final TextEditingController tokenController = TextEditingController();
    final TextEditingController destinationController = TextEditingController();
    
    // Show dialog to get FCM token and destination
    String? testResult = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('🚗 Test Journey Notification'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter Device A FCM token to send journey notification:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: tokenController,
                decoration: const InputDecoration(
                  hintText: 'Paste Device A FCM token here...',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 16),
              const Text(
                'Destination (optional):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: destinationController,
                decoration: const InputDecoration(
                  hintText: 'Test Destination - Device B',
                  border: OutlineInputBorder(),
                ),
                maxLength: 100,
              ),
              const SizedBox(height: 8),
              const Text(
                'This will create a journey notification in Firestore for Device A to detect.',
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
                  const SnackBar(content: Text('Please enter Device A FCM token')),
                );
                return;
              }
              Navigator.of(context).pop('send');
            },
            child: const Text('Send Journey Notification'),
          ),
        ],
      ),
    );

    if (testResult == 'send') {
      final token = tokenController.text.trim();
      final destination = destinationController.text.trim().isEmpty ? 'Test Destination - Device B' : destinationController.text.trim();
      
      setState(() => _isLoading = true);
      
      try {
        final currentTime = TimeOfDay.now().format(context);
        
        print('🚗 Sending journey notification via FCM token to Device A');
        print('📤 Token: ${token.length > 20 ? '${token.substring(0, 20)}...' : token}');
        
        // Create journey notification in Firestore that Device A should detect
        await _firestore.collection('journey_notifications').add({
          'type': 'journey_started',
          'fromUserId': _currentUserId ?? 'device_b_user',
          'fromUserName': _currentUserName ?? 'Device B User',
          'userName': _currentUserName ?? 'Device B User',
          'destination': destination,
          'startTime': currentTime,
          'fromLocation': 'Device B Test Location',
          'currentLocation': 'Device B Test Location',
          'targetToken': token, // FCM token for Device A
          'timestamp': FieldValue.serverTimestamp(),
          'read': false,
          'priority': 'normal',
          'isEmergency': false,
          'notificationType': 'journey_notification',
          /////notififcation display data
          'title': '🚗 Journey Started (Device B Test)',
          'body': '${_currentUserName ?? 'Device B User'} started journey to $destination at $currentTime.\n📍 Tap to view live location and track progress',
          'customFormat': true,
          'displayFormat': 'emergency_page', // Device A should listen for this
          // Test metadata
          'journeyId': 'device_b_test_${DateTime.now().millisecondsSinceEpoch}',
          'createdAt': FieldValue.serverTimestamp(),
          'isTest': true,
          'testSource': 'device_b_myprofile',
        });
        
        print('✅ Journey notification created in Firestore for Device A');
        
        _showMessage('🚗 Journey notification sent! Device A should receive it if listening.', isError: false);
      } catch (e) {
        print('❌ Journey test failed: $e');
        _showMessage('❌ Journey test failed: $e', isError: true);
      } finally {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _removeConnection(String docId) async {
    try {
      await _firestore
          .collection('users')
          .doc(_currentUserId!)
          .collection('connected_fcm_devices')
          .doc(docId)
          .delete();
      
      await _loadConnectedDevices();
      _showMessage('✅ Device connection removed', isError: false);
    } catch (e) {
      _showMessage('❌ Failed to remove connection: $e', isError: true);
    }
  }

  void _showMessage(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  void _copyTokenToClipboard() {
    if (_currentUserToken != null) {
      Clipboard.setData(ClipboardData(text: _currentUserToken!));
      _showMessage('📋 Token copied to clipboard!', isError: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My FCM Profile'),
        backgroundColor: const Color(0xFF4CAF50),
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // User Info Section
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '👤 Current User',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[700],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _currentUserName ?? 'Unknown User',
                            style: const TextStyle(fontSize: 16),
                          ),
                          Text(
                            'User ID: ${_currentUserId ?? 'Not available'}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Current Device FCM Token Section
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '📱 This Device (Device B)',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[700],
                                ),
                              ),
                              IconButton(
                                onPressed: _copyTokenToClipboard,
                                icon: const Icon(Icons.copy),
                                tooltip: 'Copy token',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey[100],
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey[300]!),
                            ),
                            child: SelectableText(
                              _currentUserToken ?? 'Loading token...',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '💡 Share this token with Device A to establish connection',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Connect New Device Section
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '🔗 Connect Device A',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[700],
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _deviceBTokenController,
                            decoration: const InputDecoration(
                              labelText: 'Device A FCM Token',
                              hintText: 'Paste Device A FCM token here...',
                              border: OutlineInputBorder(),
                            ),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _connectDevice,
                              icon: const Icon(Icons.link),
                              label: const Text('Connect Device'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF4CAF50),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Connected Devices Section
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '📲 Connected Devices (${_connectedDevices.length})',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey[700],
                                ),
                              ),
                              if (_connectedDevices.isNotEmpty)
                                IconButton(
                                  onPressed: _testSOSToConnectedDevices,
                                  icon: const Icon(Icons.emergency),
                                  tooltip: 'Test SOS',
                                  color: Colors.red,
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_connectedDevices.isEmpty)
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.grey[50],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Center(
                                child: Text(
                                  'No connected devices\nConnect Device A to enable SOS alerts',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey),
                                ),
                              ),
                            )
                          else
                            ...(_connectedDevices.map((device) {
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.green[50],
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.green[200]!),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.smartphone, color: Colors.green),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            device['deviceName'] ?? 'Connected Device',
                                            style: const TextStyle(fontWeight: FontWeight.bold),
                                          ),
                                          Text(
                                            () {
                                              final token = device['deviceToken'] as String;
                                              return 'Token: ${token.length > 20 ? '${token.substring(0, 20)}...' : token}';
                                            }(),
                                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () => _removeConnection(device['docId']),
                                      icon: const Icon(Icons.delete),
                                      color: Colors.red,
                                      tooltip: 'Remove connection',
                                    ),
                                  ],
                                ),
                              );
                            }).toList()),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Test SOS Button (if devices connected)
                  if (_connectedDevices.isNotEmpty)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _testSOSToConnectedDevices,
                        icon: const Icon(Icons.emergency),
                        label: const Text('🚨 TEST SOS TO CONNECTED DEVICES'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  
                  const SizedBox(height: 12),
                  
                  // Test Journey Notification Button (if devices connected)
                  if (_connectedDevices.isNotEmpty)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _testJourneyNotificationToConnectedDevices,
                        icon: const Icon(Icons.directions_car),
                        label: const Text('🚗 TEST JOURNEY NOTIFICATION'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  
                  const SizedBox(height: 12),
                  
                  // Debug: Check FCM Token Based Notifications
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        try {
                          final user = FirebaseAuth.instance.currentUser;
                          if (user == null) {
                            _showMessage('❌ No authenticated user', isError: true);
                            return;
                          }
                          
                          print('🔍 DEBUG: Checking FCM token based notifications...');
                          print('👤 Current user: ${user.uid}');
                          print('📧 Current email: ${user.email}');
                          
                          // Get current device FCM token
                          String? currentToken = await FirebaseMessaging.instance.getToken();
                          print('📱 Current FCM token: ${currentToken != null && currentToken.length > 20 ? '${currentToken.substring(0, 20)}...' : (currentToken ?? 'null')}');
                          
                          // Check for journey notifications targeting this FCM token
                          final querySnapshot = await _firestore
                              .collection('journey_notifications')
                              .where('targetToken', isEqualTo: currentToken)
                              .limit(10)
                              .get();
                          
                          print('📊 Found ${querySnapshot.docs.length} journey notifications for this FCM token');
                          
                          if (querySnapshot.docs.isEmpty) {
                            _showMessage('ℹ️ No journey notifications found for this FCM token', isError: false);
                          } else {
                            for (final doc in querySnapshot.docs) {
                              final data = doc.data();
                              print('📄 Notification: ${data['title']} from ${data['fromUserName']} at ${data['startTime']}');
                            }
                            _showMessage('📋 Found ${querySnapshot.docs.length} notifications targeting this token - check console', isError: false);
                          }
                          
                          // Re-initialize listeners for FCM token based notifications
                          print('🔄 Re-initializing FCM token listeners...');
                          await NotificationService.initializeEmergencyPageListeners();
                          
                        } catch (e) {
                          print('❌ Debug check failed: $e');
                          _showMessage('❌ Debug check failed: $e', isError: true);
                        }
                      },
                      icon: const Icon(Icons.bug_report),
                      label: const Text('🔍 DEBUG FCM TOKEN LISTENERS'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  @override
  void dispose() {
    _deviceBTokenController.dispose();
    super.dispose();
  }
}