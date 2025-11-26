import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalImageHelper {
  // Save image to local app storage
  static Future<String?> saveImageLocally(File imageFile) async {
    try {
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        throw Exception('No authenticated user');
      }
      
      // Get the app's documents directory
      final Directory appDocDir = await getApplicationDocumentsDirectory();
      final String profileImagesPath = '${appDocDir.path}/profile_images';
      
      // Create the directory if it doesn't exist
      final Directory profileImagesDir = Directory(profileImagesPath);
      if (!await profileImagesDir.exists()) {
        await profileImagesDir.create(recursive: true);
      }
      
      // Create the file path
      final String fileName = '${currentUser.uid}_profile.jpg';
      final String filePath = '$profileImagesPath/$fileName';
      
      // Copy the image to the app directory
      final File savedImage = await imageFile.copy(filePath);
      
      print('Image saved locally at: $filePath');
      
      // Save the local path to SharedPreferences for easy access
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('profile_image_path', savedImage.path);
      
      // Also save to Firestore (just the fact that user has a local image, not the image itself)
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .update({
        'hasLocalProfileImage': true,
        'lastUpdated': FieldValue.serverTimestamp(),
      });
      
      return savedImage.path;
    } catch (e) {
      print('Error saving image locally: $e');
      return null;
    }
  }
  
  // Get saved local image path
  static Future<String?> getLocalImagePath() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? imagePath = prefs.getString('profile_image_path');
      
      if (imagePath != null) {
        final File imageFile = File(imagePath);
        if (await imageFile.exists()) {
          return imagePath;
        } else {
          // File no longer exists, clean up the preference
          await prefs.remove('profile_image_path');
        }
      }
      
      return null;
    } catch (e) {
      print('Error getting local image path: $e');
      return null;
    }
  }
  
  // Delete local profile image
  static Future<bool> deleteLocalImage() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? imagePath = prefs.getString('profile_image_path');
      
      if (imagePath != null) {
        final File imageFile = File(imagePath);
        if (await imageFile.exists()) {
          await imageFile.delete();
        }
        await prefs.remove('profile_image_path');
      }
      
      // Update Firestore
      final User? currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .update({
          'hasLocalProfileImage': false,
          'lastUpdated': FieldValue.serverTimestamp(),
        });
      }
      
      return true;
    } catch (e) {
      print('Error deleting local image: $e');
      return false;
    }
  }
}