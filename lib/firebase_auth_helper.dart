// Helper class to handle Firebase Authentication with error recovery
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class FirebaseAuthHelper {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Sign up with email and password with error handling
  static Future<UserCredential?> signUpWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      // Attempt normal sign up
      final UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      return userCredential;
    } on TypeError catch (e) {
      print('Type error during sign up, attempting recovery: $e');
      
      // Wait a bit and retry
      await Future.delayed(const Duration(seconds: 1));
      
      try {
        final UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
        
        return userCredential;
      } catch (retryError) {
        print('Retry failed: $retryError');
        rethrow;
      }
    } catch (e) {
      print('Sign up error: $e');
      rethrow;
    }
  }

  /// Sign in with email and password with error handling
  static Future<UserCredential?> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      // Attempt normal sign in
      final UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      return userCredential;
    } on TypeError catch (e) {
      print('Type error during sign in, attempting recovery: $e');
      
      // Wait a bit and retry
      await Future.delayed(const Duration(seconds: 1));
      
      try {
        final UserCredential userCredential = await _auth.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
        
        return userCredential;
      } catch (retryError) {
        print('Retry failed: $retryError');
        rethrow;
      }
    } catch (e) {
      print('Sign in error: $e');
      rethrow;
    }
  }

  /// Store user data in Firestore with error handling
  static Future<void> storeUserData({
    required String userId,
    required String email,
    required String mobileNumber,
  }) async {
    try {
      final Map<String, dynamic> userData = {
        'email': email,
        'mobileNumber': mobileNumber,
        'createdAt': FieldValue.serverTimestamp(),
        'lastSignIn': FieldValue.serverTimestamp(),
      };
      
      await _firestore.collection('users').doc(userId).set(userData);
    } catch (e) {
      print('Error storing user data: $e');
      rethrow;
    }
  }

  /// Update last sign-in time
  static Future<void> updateLastSignIn(String userId) async {
    try {
      await _firestore.collection('users').doc(userId).update({
        'lastSignIn': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating last sign-in: $e');
      rethrow;
    }
  }
}