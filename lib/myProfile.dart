import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:safego/sos.dart';
import 'package:safego/sign_in.dart';
import 'package:safego/editProfile.dart';
import 'package:safego/homepage.dart';
import 'package:safego/emerConList.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:safego/local_image_helper.dart';
import 'package:safego/widgets/profile_avatar.dart';
import 'package:safego/emercontpage.dart' as emer;
import 'package:safego/notification_service.dart';
import 'dart:io';
import 'package:safego/chat_page.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class MyProfile extends StatefulWidget {
  const MyProfile({super.key});

  @override
  MyProfileState createState() => MyProfileState();
}

class MyProfileState extends State<MyProfile> {
  // User data - fetched from Firebase
  String userName = "";
  String userEmail = "";
  String userPhone = "";
  String? profileImagePath; // null means using default profile icon
  bool _isLoading = true;
  
  // FCM Connection variables
  final TextEditingController _emergencyContactTokenController = TextEditingController();
  String? _currentUserToken;
  String? _currentUserId;
  String? _currentUserName;
  List<Map<String, dynamic>> _connectedDevices = [];
  bool _isFCMLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _initializeFCM();
  }

  // Method to fetch user data from Firebase
  Future<void> _loadUserData() async {
    try {
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        // Get user email from Firebase Auth
        setState(() {
          userEmail = currentUser.email ?? '';
          // Extract name from email (before @ symbol) as a fallback
          userName = currentUser.displayName ?? userEmail.split('@')[0];
        });

        // Try to get additional data from Firestore
        try {
          final DocumentSnapshot userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(currentUser.uid)
              .get();

          if (userDoc.exists) {
            final userData = userDoc.data() as Map<String, dynamic>?;
            if (userData != null) {
              setState(() {
                userPhone = userData['mobileNumber'] ?? '';
                // Update other fields if available in Firestore
                if (userData['displayName'] != null) {
                  userName = userData['displayName'];
                }
                // Load profile image URL (deprecated field)
                if (userData['profileImageUrl'] != null) {
                  profileImagePath = userData['profileImageUrl'];
                }
        

              });
            }
          }
        } catch (firestoreError) {
          print('Error fetching user data from Firestore: $firestoreError');
          // Continue with Firebase Auth data only
        }
      }
    } catch (e) {
      print('Error loading user data: $e');
      // Set fallback values if something goes wrong
      setState(() {
        userName = "User";
        userEmail = "No email available";
        userPhone = "No phone available";
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
    
    // Load local image if available
    _loadLocalImage();
  }
  
  // Load local profile image
  Future<void> _loadLocalImage() async {
    final String? localImagePath = await LocalImageHelper.getLocalImagePath();
    if (localImagePath != null) {
      setState(() {
        profileImagePath = localImagePath;
      });
    }
  }

  // Initialize FCM and load connected devices
  Future<void> _initializeFCM() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        _currentUserId = user.uid;
        _currentUserName = user.displayName ?? user.email?.split('@')[0] ?? 'SafeGo User';
        
        // Get FCM token
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null) {
          setState(() {
            _currentUserToken = token;
          });
        }
        
        // Load connected devices
        _loadConnectedDevices();
      }
    } catch (e) {
      print('Error initializing FCM: $e');
    }
  }

  // Load connected emergency contact devices
  Future<void> _loadConnectedDevices() async {
    if (_currentUserId == null) return;
    
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId!)
          .collection('connected_fcm_devices')
          .where('isActive', isEqualTo: true)
          .get();
      
      setState(() {
        _connectedDevices = snapshot.docs.map((doc) {
          final data = doc.data();
          data['docId'] = doc.id;
          return data;
        }).toList();
      });
    } catch (e) {
      print('Error loading connected devices: $e');
    }
  }

  // Connect to emergency contact device
  Future<void> _connectToEmergencyContact() async {
    if (_currentUserId == null || _currentUserToken == null) {
      _showMessage('❌ FCM not initialized', isError: true);
      return;
    }

    final emergencyContactToken = _emergencyContactTokenController.text.trim();
    
    if (emergencyContactToken.isEmpty) {
      _showMessage('❌ Please enter emergency contact FCM token', isError: true);
      return;
    }
    
    if (emergencyContactToken == _currentUserToken) {
      _showMessage('❌ Cannot connect to your own device', isError: true);
      return;
    }

    setState(() => _isFCMLoading = true);

    try {
      // Save emergency contact token in current user's connected devices
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId!)
          .collection('connected_fcm_devices')
          .add({
        'deviceToken': emergencyContactToken,
        'deviceName': 'Emergency Contact',
        'connectedAt': FieldValue.serverTimestamp(),
        'isActive': true,
      });

      // Also save in global connections for bidirectional communication
      await FirebaseFirestore.instance.collection('fcm_connections').add({
        'deviceA': _currentUserToken,
        'deviceB': emergencyContactToken,
        'userIdA': _currentUserId,
        'userNameA': _currentUserName,
        'connectedAt': FieldValue.serverTimestamp(),
        'isActive': true,
      });

      _emergencyContactTokenController.clear();
      _showMessage('✅ Emergency contact connected successfully!');
      _loadConnectedDevices();
    } catch (e) {
      _showMessage('❌ Failed to connect: $e', isError: true);
    } finally {
      setState(() => _isFCMLoading = false);
    }
  }

  // Remove connected device
  Future<void> _removeConnectedDevice(String docId) async {
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUserId!)
          .collection('connected_fcm_devices')
          .doc(docId)
          .delete();
      
      _showMessage('✅ Device disconnected');
      _loadConnectedDevices();
    } catch (e) {
      _showMessage('❌ Failed to remove device: $e', isError: true);
    }
  }

  // Show message helper
  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // Copy FCM token to clipboard
  Future<void> _copyTokenToClipboard() async {
    if (_currentUserToken != null) {
      await Clipboard.setData(ClipboardData(text: _currentUserToken!));
      _showMessage('📋 FCM token copied to clipboard!');
    }
  }




  void _signOut() {
    showDialog(
      context: context,
      barrierDismissible: false, // Prevent dismissing by tapping outside
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          elevation: 10,
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color.fromARGB(255, 255, 225, 190),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.logout,
                  color: Colors.black,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Sign Out',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: const Text(
            'Are you sure you want to sign out of your SafeGo account?',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 16,
              height: 1.4,
            ),
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      Navigator.of(context).pop(); // Close the dialog
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.grey[100],
                      foregroundColor: Colors.black54,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton(
                    onPressed: () async {
                      Navigator.of(context).pop(); // Close the dialog
                      
                      try {
                        // Sign out from Firebase
                        await FirebaseAuth.instance.signOut();
                        
                        // Keep biometric credentials for quick sign-in next time
                        // No need to clear saved credentials
                        
                        // Navigate to sign in page and remove all previous routes
                        Navigator.of(context).pushAndRemoveUntil(
                          MaterialPageRoute(builder: (context) => const SignIn()),
                          (Route<dynamic> route) => false,
                        );
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error signing out: $e')),
                        );
                      }
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Sign Out',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // Method to navigate to edit profile
  void _editProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const EditProfile()),
    );
  }

  // Method to navigate to home page
  void _navigateToHome() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const HomePage()),
    );
  }

  // Method to navigate to emergency contacts
  void _navigateToEmergencyContacts() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const EmerConList()),
    );
  }

  // Method to navigate to chat (placeholder for future implementation)
  void _navigateToChat() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ChatPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190), // Override AppBar background color
        foregroundColor: Colors.black, // Override AppBar icon/text color
        centerTitle: true,
        title: const Text(
          'My Profile',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        elevation: 4,
        shadowColor: Colors.black54,
        leading: IconButton(
          icon: const Icon(Icons.logout),
          onPressed: _signOut,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: ProfileAvatar(
              size: 40,
              onTap: () {
                // Profile icon action - already on profile page
              },
            ),
          ),
        ],
      ),

      ///////////////Start BottomNavigationBar//////////////////
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
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
          currentIndex: 1, // Profile tab is selected
          onTap: (index) {
            if (index == 0) {
              _navigateToHome(); // Navigate to home
            }
            // Index 1 is current page (Profile), so no navigation needed
          },
          items: const [
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
        // Increased size for bigger button
        width: 80,
        height: 80,
        child: FloatingActionButton(
          onPressed: () {
            EmergencyAlert.show(context);
          },
          backgroundColor: Colors.white,
          heroTag: "profileSosButton", // Unique hero tag
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

      // Main body content
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(20),
          ),
        ),
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Color.fromARGB(255, 255, 225, 190)),
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
              // Page Title centered with Edit Icon in top right
              Stack(
                children: [
                  // Centered title
                  Center(
                    child: Text(
                      'My Profile',
                      style: TextStyle(
                        fontSize: 35,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  // Edit icon positioned in top right
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      onPressed: _editProfile,
                      icon: const Icon(
                        Icons.edit_note,
                        color: Colors.black,
                        size: 40,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 20),

              // Profile Picture Section
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.grey[200],
                  border: Border.all(
                    color: Colors.grey[400]!,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: profileImagePath != null
                    ? ClipOval(
                        child: profileImagePath!.startsWith('http')
                            ? Image.network(
                                profileImagePath!,
                                width: 120,
                                height: 120,
                                fit: BoxFit.cover,
                                loadingBuilder: (context, child, loadingProgress) {
                                  if (loadingProgress == null) return child;
                                  return const CircularProgressIndicator(
                                    valueColor: AlwaysStoppedAnimation<Color>(Color.fromARGB(255, 255, 225, 190)),
                                  );
                                },
                                errorBuilder: (context, error, stackTrace) {
                                  return Icon(
                                    Icons.person,
                                    size: 60,
                                    color: Colors.grey[600],
                                  );
                                },
                              )
                            : Image.file(
                                File(profileImagePath!),
                                width: 120,
                                height: 120,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Icon(
                                    Icons.person,
                                    size: 60,
                                    color: Colors.grey[600],
                                  );
                                },
                              ),
                      )
                    : Icon(
                        Icons.person,
                        size: 60,
                        color: Colors.grey[600],
                      ),
              ),

              const SizedBox(height: 15),

              // User Name
              Text(
                userName.isNotEmpty ? userName : 'Loading...',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),

              const SizedBox(height: 8),
              // Small contacts button (similar to Journey contacts behavior)
              SizedBox(
                width: 220,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: const Color.fromARGB(255, 255, 241, 217),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    side: const BorderSide(color: Colors.black12),
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                  ),
                  icon: const Icon(Icons.contact_phone, color: Colors.black),
                  label: const Text('Emergency Contact Page', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  onPressed: () {
                    // Navigate directly to emergency contacts page without biometric gating
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const emer.HomePage()),
                    );
                  },
                ),
              ),

              const SizedBox(height: 30),

              // Profile Information Cards
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      // Email
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Email',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          Text(
                            userEmail.isNotEmpty ? userEmail : 'Not available',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: userEmail.isNotEmpty ? Colors.black : Colors.grey,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Phone
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Phone',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          Text(
                            userPhone.isNotEmpty ? userPhone : 'Not available',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: userPhone.isNotEmpty ? Colors.black : Colors.grey,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // Emergency Contacts Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey[200],
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                            elevation: 2,
                          ),
                            onPressed: _navigateToEmergencyContacts,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Click to view emergency contacts',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black,
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward_ios,
                                color: Colors.black54,
                                size: 16,
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Chat Button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey[200],
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                            elevation: 2,
                          ),
                          onPressed: _navigateToChat,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Chat with SafeGo chatbot',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black,
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward_ios,
                                color: Colors.black54,
                                size: 16,
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // FCM Token Debug Buttons (only visible in debug mode)
                      if (kDebugMode) ...[
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue[100],
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                              elevation: 2,
                            ),
                            onPressed: () => NotificationService.displayFCMTokenInfo(context),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Show My FCM Token',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                                const Icon(
                                  Icons.info_outline,
                                  color: Colors.black54,
                                  size: 16,
                                ),
                              ],
                            ),
                          ),
                        ),












                        const SizedBox(height: 16),

                        // FCM Emergency Contact Connection Section
                        Card(
                          elevation: 4,
                          margin: const EdgeInsets.only(bottom: 16),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.notification_important, color: Colors.orange),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Emergency Contact Connection',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                
                                // Connect to Emergency Contact Section
                                Text(
                                  'Connect to Emergency Contact:',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey[700],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _emergencyContactTokenController,
                                        decoration: InputDecoration(
                                          hintText: 'Enter emergency contact FCM token',
                                          border: OutlineInputBorder(),
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        ),
                                        maxLines: 3,
                                        minLines: 1,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton(
                                      onPressed: _isFCMLoading ? null : _connectToEmergencyContact,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green,
                                        foregroundColor: Colors.white,
                                      ),
                                      child: _isFCMLoading 
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                            )
                                          : const Text('Connect'),
                                    ),
                                  ],
                                ),
                                
                                const SizedBox(height: 16),
                                
                                // Connected Devices List
                                if (_connectedDevices.isNotEmpty) ...[
                                  Text(
                                    'Connected Emergency Contacts:',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey[700],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ..._connectedDevices.map((device) => Card(
                                    color: Colors.green[50],
                                    child: ListTile(
                                      leading: const Icon(Icons.devices, color: Colors.green),
                                      title: Text(device['deviceName'] ?? 'Emergency Contact'),
                                      subtitle: Text(() {
                                        final token = device['deviceToken'] as String;
                                        return 'Token: ${token.length > 20 ? '${token.substring(0, 20)}...' : token}';
                                      }()),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.delete, color: Colors.red),
                                        onPressed: () => _removeConnectedDevice(device['docId']),
                                        tooltip: 'Disconnect',
                                      ),
                                    ),
                                  )).toList(),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],

                      // Sign Out Button (moved to last) - Capsule size
                      Center(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(255, 255, 231, 204),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(25),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 34),
                            elevation: 4,
                          ),
                          onPressed: _signOut,
                          child: const Text(
                            'SIGN OUT',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),
                    ],
                  ),
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
    _emergencyContactTokenController.dispose();
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
                        56.0 - // Standard bottom navigation bar height
                        (scaffoldGeometry.floatingActionButtonSize.height / 2); // Half the button height to center it on nav bar
    
    return Offset(fabX, fabY);
  }
}
