import 'package:flutter/material.dart';
import 'package:safego/homepage.dart';
import 'package:safego/myProfile.dart';
import 'package:safego/widgets/profile_avatar.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:safego/sos.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
// import 'package:safego/firestore_notifications.dart';
import 'package:safego/models/emergency_contact.dart';
import 'dart:async';
import 'dart:convert';
import 'package:safego/notifications.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:safego/emercontpage.dart' as emer;
import 'package:safego/notification_service.dart';


class EmerCont extends StatefulWidget {
  const EmerCont({super.key});

  @override
  EmerContState createState() => EmerContState();
}

class EmerContState extends State<EmerCont> {
  File? _profileImage;
  final ImagePicker _picker = ImagePicker();
  
  // Text controllers for form inputs
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _relationshipController = TextEditingController();
  
  // Toggle switches for access controls
  bool _allowShareLiveLocation = false;
  bool _notifyWhenSafelyArrived = false;
  bool _shareLiveLocationDuringSOS = false;

  // Method to show image picker dialog
  void _showImagePickerDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Select Profile Picture'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Camera'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Gallery'),
                onTap: () {
                  Navigator.of(context).pop();
                  _pickImage(ImageSource.gallery);
                },
              ),
              if (_profileImage != null)
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: const Text('Remove Picture'),
                  onTap: () {
                    Navigator.of(context).pop();
                    _removeImage();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  // Method to pick image from camera or gallery
  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        setState(() {
          _profileImage = File(pickedFile.path);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick image: $e')),
      );
    }
  }

  // Method to remove the selected image
  void _removeImage() {
    setState(() {
      _profileImage = null;
    });
  }

  // Method to save contact and navigate back
  Future<void> _saveContact() async {
    // Validate form
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a name'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_phoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a phone number'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (_relationshipController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter the relationship'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }



    try {
      // Show loading indicator
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return const Center(
            child: CircularProgressIndicator(),
          );
        },
      );

      // Get current user
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        throw Exception('User not authenticated');
      }

      // Ensure a users/{uid} document exists so other apps can resolve by email
      await _ensureUserDoc(currentUser);

      // Try to find the emergency contact's Firebase User ID for FCM
      String? emergencyContactUserId;
      try {
        // Look up user by phone number or name in the users collection
        final userQuery = await FirebaseFirestore.instance
            .collection('users')
            .where('phoneNumber', isEqualTo: _phoneController.text.trim())
            .get();
        
        if (userQuery.docs.isNotEmpty) {
          emergencyContactUserId = userQuery.docs.first.id;
          debugPrint('Found emergency contact Firebase UID: $emergencyContactUserId');
        } else {
          debugPrint('Emergency contact not found in Firebase users - FCM notifications will not work');
        }
      } catch (e) {
        debugPrint('Error looking up emergency contact UID: $e');
      }

      // Create emergency contact object
      final emergencyContact = EmergencyContact(
        id: '', // Firebase will generate the ID
        name: _nameController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
        email: '', // No email field
        relationship: _relationshipController.text.trim(),
        profileImage: _profileImage,
        allowShareLiveLocation: _allowShareLiveLocation,
        notifyWhenSafelyArrived: _notifyWhenSafelyArrived,
        shareLiveLocationDuringSOS: _shareLiveLocationDuringSOS,
        createdAt: DateTime.now(),
      );

      // Save to Firestore with emergency contact user ID for FCM
      final contactData = emergencyContact.toFirestore();
      if (emergencyContactUserId != null) {
        contactData['emergencyContactId'] = emergencyContactUserId; // Add FCM targeting
      }
      
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .collection('emergency_contacts')
          .add(contactData);

      // Close loading dialog
      if (mounted) {
        Navigator.of(context).pop();
      }

        // Show success message and add notification
        if (mounted) {
          // Add immediate in-app notification entry FIRST
          NotificationsManager.instance.add(
            '${FirebaseAuth.instance.currentUser?.displayName?.trim() ?? FirebaseAuth.instance.currentUser?.email?.split('@')[0] ?? 'SafeGo user'} added to emergency contacts', 
            body: 'Successfully added as an emergency contact. Tap to view all contacts.'
          );

          // Show local system notification for better visibility (using existing service)
          try {
            await _showContactAddedSystemNotification(_nameController.text.trim());
          } catch (e) {
            // Non-fatal - continue with UI feedback
            debugPrint('Failed to show system notification: $e');
          }

          // Send FCM notification to newly added emergency contact
          try {
            await _sendEmergencyContactAddedFCM(
              contactName: _nameController.text.trim(),
              contactPhone: _phoneController.text.trim(),
            );
            debugPrint('FCM notification sent to newly added emergency contact');
          } catch (e) {
            debugPrint('Failed to send FCM notification to emergency contact: $e');
            // Non-fatal - continue with UI feedback
          }

          // Send FCM notification to connected Device B
          try {
            await NotificationService.sendToConnectedDevices(
              title: '✅ Emergency Contact Added',
              body: '"${FirebaseAuth.instance.currentUser?.displayName?.trim() ?? FirebaseAuth.instance.currentUser?.email?.split('@')[0] ?? 'SafeGo user'}" added you as an emergency contact.',
              notificationType: 'emergency_contact_added',
              additionalData: {
                'contactName': _nameController.text.trim(),
                'contactPhone': _phoneController.text.trim(),
                'relationship': _relationshipController.text.trim(),
                'timestamp': DateTime.now().toIso8601String(),
              },
            );
            debugPrint('📤 FCM notification sent to Device B - emergency contact added');
          } catch (e) {
            debugPrint('Failed to send FCM notification to Device B: $e');
            // Non-fatal - continue with UI feedback
          }

          // Show immediate success snackbar
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${FirebaseAuth.instance.currentUser?.displayName?.trim() ?? FirebaseAuth.instance.currentUser?.email?.split('@')[0] ?? 'SafeGo user'} added to emergency contacts! FCM notification sent.',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          );

          // Show success dialog
          showDialog(
            context: context,
            builder: (BuildContext context) {
              return Dialog(
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
                            '${_nameController.text.trim()} has been added as an emergency contact',
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
                          Navigator.of(context).pop(); // Close dialog
                          Navigator.pop(context, true); // Navigate back to emergency contact list
                        },
                        child: const Text(
                          'OK',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );

          // Broadcast to in-app listeners (emergency contacts added)
          emer.ContactNotifier.instance.addContact(_nameController.text.trim());
            try {
              await _notifyEmersgApp(_nameController.text.trim());
            } catch (e) {
              // Non-fatal — continue happy path
              print('Failed to notify emersg app via file: $e');
            }

          // Persist the notification under the current user's Firestore notifications
          try {
            final notifData = {
              'title': '${FirebaseAuth.instance.currentUser?.displayName?.trim() ?? FirebaseAuth.instance.currentUser?.email?.split('@')[0] ?? 'SafeGo user'} added to emergency contacts',
              'body': 'Tap to view emergency contacts.',
                'type': 'contact_added',
                'topic': 'emersg',
              'relatedContactName': _nameController.text.trim(),
              'read': false,
              'userId': currentUser.uid,
              'createdAt': FieldValue.serverTimestamp(),
            };

            // Per-user subcollection (backwards compatibility)
            final notifRef = FirebaseFirestore.instance
                .collection('users')
                .doc(currentUser.uid)
                .collection('notifications');

            await notifRef.add(notifData);

            // Also write to a top-level notifications collection so all devices
            // (and any backends) can more easily query notifications for a user.
            await FirebaseFirestore.instance.collection('notifications').add(notifData);
          } catch (e) {
            // Don't block the happy path if notification persistence fails; log for debugging
            print('Failed to persist notification in Firestore: $e');
          }


        }
    } catch (e) {
      // Close loading dialog if still open
      if (mounted) {
        Navigator.of(context).pop();
      }
      
      // Show error message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add contact: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      print('Error saving emergency contact: $e');
    }
  }

  /// Send FCM notification when emergency contact is added
  Future<void> _sendEmergencyContactAddedFCM({
    required String contactName,
    required String contactPhone,
  }) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      final currentUserName = currentUser.displayName?.trim() ?? 
                            currentUser.email?.split('@')[0] ?? 
                            'SafeGo user';

      // Look up the emergency contact's Firebase User ID
      String? emergencyContactUserId;
      try {
        final userQuery = await FirebaseFirestore.instance
            .collection('users')
            .where('phoneNumber', isEqualTo: contactPhone)
            .get();
        
        if (userQuery.docs.isNotEmpty) {
          emergencyContactUserId = userQuery.docs.first.id;
        }
      } catch (e) {
        debugPrint('Error looking up emergency contact for FCM: $e');
      }

      if (emergencyContactUserId == null) {
        debugPrint('Emergency contact $contactName not found in Firebase - skipping FCM notification');
        return;
      }

      // Create notification data for emergency contact added
      final notificationData = {
        'type': 'emergency_contact_added',
        'title': 'Added to Emergency Contacts',
        'body': '$currentUserName has added you to their emergency contacts in SafeGo',
        'fromUserId': currentUser.uid,
        'toUserId': emergencyContactUserId, // Critical: target the right user
        'senderName': currentUserName,
        'contactName': contactName,
        'contactPhone': contactPhone,
        'timestamp': FieldValue.serverTimestamp(),
        'read': false,
      };

      // Add to emergency_notifications collection for real-time FCM processing
      await FirebaseFirestore.instance
          .collection('emergency_notifications')
          .add(notificationData);

      debugPrint('Emergency contact added FCM notification queued for: $contactName (UID: $emergencyContactUserId)');
    } catch (e) {
      debugPrint('Error sending emergency contact added FCM: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190), // Override AppBar background color
        foregroundColor: Colors.black, // Override AppBar icon/text color
        centerTitle: true,
        title: const Text(
          'SafeGo',
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        elevation: 4,
        shadowColor: Colors.black54,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context); // go to previous screen
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
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          children: [
            const Text(
              'Input Emergency Contacts',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),

            const SizedBox(height: 10),

            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: _showImagePickerDialog,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.grey[200],
                      border: Border.all(
                        color: Colors.grey[400]!,
                        width: 2,
                      ),
                    ),
                    child: _profileImage != null
                        ? ClipOval(
                            child: Image.file(
                              _profileImage!,
                              width: 120,
                              height: 120,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.grey[300],
                            ),
                            child: Icon(
                              Icons.person,
                              size: 60,
                              color: Colors.grey[600],
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tap to change profile picture',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
            const SizedBox(height: 12),

            Column(
              children: [
                Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                  'Name',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                  const SizedBox(width: 230),
                  const Text(
                  'Enter name',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                ],
                ),
                const SizedBox(height: 3),
                TextField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'John Applese',
                  filled: true,
                  fillColor: const Color.fromARGB(166, 231, 231, 231),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                ),
                ),
                const SizedBox(height: 8),
                Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                  'Mobile Number',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                  const SizedBox(width: 130),
                  const Text(
                  'Enter mobile number',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                ],
                ),
                const SizedBox(height: 3),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: '+6013 456 7890',
                    filled: true,
                    fillColor: const Color.fromARGB(166, 231, 231, 231),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(Icons.phone),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  const Text(
                  'Relationship',
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                ],
                ),
                const SizedBox(height: 3),
                TextField(
                  controller: _relationshipController,
                  decoration: InputDecoration(
                    labelText: 'e.g., Mother, Father, Friend',
                    filled: true,
                    fillColor: const Color.fromARGB(166, 231, 231, 231),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(Icons.people),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  ),
                ),
                const SizedBox(height: 3),
              ],
            ),
          
            const SizedBox(height: 8),
            
            // Toggle 1: Allow Share Live Location
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Share Live Location ',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
                Switch(
                  value: _allowShareLiveLocation,
                  onChanged: (bool value) {
                    setState(() {
                      _allowShareLiveLocation = value;
                    });
                  },
                  activeColor: Colors.green,
                ),
              ],
            ),
            
            // Toggle 2: Notify When Safely Arrived
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Notify when you safely arrived',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
                Switch(
                  value: _notifyWhenSafelyArrived,
                  onChanged: (bool value) {
                    setState(() {
                      _notifyWhenSafelyArrived = value;
                    });
                  },
                  activeColor: Colors.green,
                ),
              ],
            ),
            // Toggle 3: Share Live Location During SOS Alert
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    'Share Live Location during SOS alert',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
                Switch(
                  value: _shareLiveLocationDuringSOS,
                  onChanged: (bool value) {
                    setState(() {
                      _shareLiveLocationDuringSOS = value;
                    });
                  },
                  activeColor: Colors.green,
                ),
              ],
            ),
                     
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 231, 155, 67), // F9E2BC color
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: _saveContact,
              child: const Text(
                'Add Contact',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ),

            const SizedBox(height: 20),
            
          ],
        ),
      ),
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
          currentIndex: 1, // Highlight the Profile icon
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
      
      floatingActionButton: SizedBox(
        width: 80, 
        height: 80, 
        child: FloatingActionButton(
          heroTag: 'sos_button_emercont',
          onPressed: () {
            EmergencyAlert.show(context);
          },
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(40),
            side: const BorderSide(color: Colors.red, width: 5),
          ),
          child: const Text(
            'SOS',
            style: TextStyle(
              color: Colors.black,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
      floatingActionButtonLocation: _CustomSOSButtonLocation(),
    );
  }

  @override
  void initState() {
    super.initState();
  }

  /// Ensure a `users/{uid}` Firestore document exists with the user's email.
  /// This allows other apps (like emersg) to resolve an email to a UID.
  Future<void> _ensureUserDoc(User user) async {
    try {
      final ref = FirebaseFirestore.instance.collection('users').doc(user.uid);
      final snap = await ref.get();
      if (!snap.exists) {
        await ref.set({
          'email': user.email ?? '',
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      // non-fatal; log for debugging
      // ignore: avoid_print
      print('ensureUserDoc failed: $e');
    }
  }

  /// Writes a small JSON notification file so the emersg app (which watches
  /// the safego workspace and LOCALAPPDATA) can detect that a contact was added.
  /// It writes both a dot-prefixed temporary file and then renames to
  /// `.contact_added.json` (atomic-ish) and also writes `contact_added.json`.
  Future<void> _notifyEmersgApp(String name) async {
    try {
      final data = {
        'name': name,
        'timestamp': DateTime.now().toIso8601String(),
      };
      final jsonStr = json.encode(data);

      // Primary workspace path used by emersg watcher
      final workspaceDir = Directory(r'C:\Users\chuba\Desktop\safego\safego');
      if (await workspaceDir.exists()) {
        final tmp = File('${workspaceDir.path}${Platform.pathSeparator}.contact_tmp');
        await tmp.writeAsString(jsonStr, flush: true);
        final target = File('${workspaceDir.path}${Platform.pathSeparator}.contact_added.json');
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
        final plain = File('${workspaceDir.path}${Platform.pathSeparator}contact_added.json');
        await plain.writeAsString(jsonStr, flush: true);
      }

      // Fallback to LOCALAPPDATA\safego (or HOME) so emersg can pick it up
      final localApp = Platform.environment['LOCALAPPDATA'] ?? Platform.environment['HOME'];
      if (localApp != null && localApp.isNotEmpty) {
        final fallbackDir = Directory('$localApp${Platform.pathSeparator}safego');
        if (!await fallbackDir.exists()) await fallbackDir.create(recursive: true);
        final tmp2 = File('${fallbackDir.path}${Platform.pathSeparator}.contact_tmp');
        await tmp2.writeAsString(jsonStr, flush: true);
        final target2 = File('${fallbackDir.path}${Platform.pathSeparator}.contact_added.json');
        if (await target2.exists()) await target2.delete();
        await tmp2.rename(target2.path);
        final plain2 = File('${fallbackDir.path}${Platform.pathSeparator}contact_added.json');
        await plain2.writeAsString(jsonStr, flush: true);
      }

      // If we're running on a desktop (developer machine), try to launch
      // the Node notifier script so the external sender sends a push
      // notification. This only works when Node is installed and on PATH.
      try {
        final script = r'C:\Users\chuba\Desktop\safego\safego-notifier\sendNotification.js';
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          // Start node in detached mode so the Flutter UI isn't blocked.
          Process.start('node', [script], mode: ProcessStartMode.detached).then((proc) {
            debugPrint('Started node sendNotification.js (pid: ${proc.pid})');
          }).catchError((e) {
            debugPrint('Failed to start node script: $e');
          });
        }
      } catch (e) {
        // Non-fatal; record for debugging
        debugPrint('Error launching node notifier: $e');
      }
    } catch (e) {
      // Non-fatal; log for debugging
      debugPrint('Failed to write contact notification file: $e');
    }
  }

  /// Show a system notification when a contact is added
  Future<void> _showContactAddedSystemNotification(String userName) async {
    try {
      final FlutterLocalNotificationsPlugin notification = FlutterLocalNotificationsPlugin();
      
      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'contact_added_channel',
        'Contact Added Notifications',
        channelDescription: 'Notifications when emergency contacts are added',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
        color: Color(0xFF4CAF50), // Green color
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

      await notification.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000, // Unique ID
        'Emergency Contact Added ✅',
       '${_nameController.text.trim()} has been successfully added as an emergency contact.',
        platformChannelSpecifics,
      );
    } catch (e) {
      debugPrint('Error showing system notification: $e');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _relationshipController.dispose();
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
