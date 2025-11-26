import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:safego/local_image_helper.dart';
import 'dart:io';

class ProfileAvatar extends StatefulWidget {
  final double size;
  final VoidCallback? onTap;
  final Color? backgroundColor;
  final Color? iconColor;
  final bool showBorder;

  const ProfileAvatar({
    Key? key,
    this.size = 40,
    this.onTap,
    this.backgroundColor,
    this.iconColor,
    this.showBorder = true,
  }) : super(key: key);

  @override
  ProfileAvatarState createState() => ProfileAvatarState();
}

class ProfileAvatarState extends State<ProfileAvatar> {
  String? _profileImagePath;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProfileImage();
  }

  Future<void> _loadProfileImage() async {
    try {
      // First try to get local image
      final String? localImagePath = await LocalImageHelper.getLocalImagePath();
      if (localImagePath != null) {
        setState(() {
          _profileImagePath = localImagePath;
          _isLoading = false;
        });
        return;
      }

      // If no local image, try to get from Firestore (legacy profile images)
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        try {
          final DocumentSnapshot userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(currentUser.uid)
              .get();

          if (userDoc.exists) {
            final userData = userDoc.data() as Map<String, dynamic>?;
            if (userData != null && userData['profileImageUrl'] != null) {
              setState(() {
                _profileImagePath = userData['profileImageUrl'];
              });
            }
          }
        } catch (firestoreError) {
          print('Error loading profile image from Firestore: $firestoreError');
        }
      }
    } catch (e) {
      print('Error loading profile image: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: widget.showBorder
            ? BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.grey[300]!,
                  width: 2,
                ),
              )
            : null,
        child: _isLoading
            ? CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  widget.iconColor ?? Colors.grey[600]!,
                ),
              )
            : _profileImagePath != null
                ? ClipOval(
                    child: _profileImagePath!.startsWith('http')
                        ? Image.network(
                            _profileImagePath!,
                            width: widget.size,
                            height: widget.size,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return _defaultIcon();
                            },
                          )
                        : Image.file(
                            File(_profileImagePath!),
                            width: widget.size,
                            height: widget.size,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return _defaultIcon();
                            },
                          ),
                  )
                : _defaultIcon(),
      ),
    );
  }

  Widget _defaultIcon() {
    return Icon(
      Icons.account_circle,
      size: widget.size,
      color: widget.iconColor ?? Colors.grey[600],
    );
  }

  // Method to refresh the profile image (call this when profile is updated)
  void refresh() {
    setState(() {
      _isLoading = true;
    });
    _loadProfileImage();
  }
}

// Global function to refresh all profile avatars when profile image changes
class ProfileAvatarManager {
  static final List<GlobalKey<ProfileAvatarState>> _avatarKeys = [];

  static GlobalKey<ProfileAvatarState> registerAvatar() {
    final key = GlobalKey<ProfileAvatarState>();
    _avatarKeys.add(key);
    return key;
  }

  static void refreshAllAvatars() {
    for (final key in _avatarKeys) {
      key.currentState?.refresh();
    }
  }

  static void unregisterAvatar(GlobalKey<ProfileAvatarState> key) {
    _avatarKeys.remove(key);
  }
}