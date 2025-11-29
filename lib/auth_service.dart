import 'package:local_auth/local_auth.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  
  Future<bool> authenticateWithBiometrics() async {
    bool isAuthenticated = false;
    try {
      isAuthenticated = await _localAuth.authenticate(
        localizedReason: 'Please authenticate to access this feature',
        options: const AuthenticationOptions(
          useErrorDialogs: true,
          stickyAuth: true,
        ),
      );
    } catch (e) {
      print(e);
    }
    return isAuthenticated;
  }
  
  // Save user credentials securely for biometric login with user ID
  Future<void> saveCredentialsForBiometric(String userId, String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('biometric_user_id', userId);
    await prefs.setString('saved_email', email);
    await prefs.setString('saved_password', password);
    await prefs.setBool('biometric_enabled', true);
    await prefs.setInt('biometric_setup_timestamp', DateTime.now().millisecondsSinceEpoch);
  }
  
  // Check if biometric login is available
  Future<bool> isBiometricLoginAvailable() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('biometric_enabled') ?? false;
  }
  
  // Biometric login with Firebase authentication and user validation
  Future<User?> biometricLoginWithFirebase() async {
    try {
      // First check biometric authentication
      bool biometricSuccess = await authenticateWithBiometrics();
      if (!biometricSuccess) {
        return null;
      }
      
      // If biometric auth successful, get saved credentials
      final prefs = await SharedPreferences.getInstance();
      final savedUserId = prefs.getString('biometric_user_id');
      final email = prefs.getString('saved_email');
      final password = prefs.getString('saved_password');
      
      if (email == null || password == null || savedUserId == null) {
        throw Exception('No saved credentials found or incomplete biometric setup');
      }
      
      // Sign in to Firebase with saved credentials
      UserCredential userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      // Verify that the logged-in user matches with the biometric setup
      if (userCredential.user != null && userCredential.user!.uid != savedUserId) {
        // Clear invalid biometric data
        await clearSavedCredentials();
        throw Exception('Biometric data does not match current user account');
      }
      
      return userCredential.user;
    } catch (e) {
      print('Biometric Firebase login error: $e');
      return null;
    }
  }
  
  // Clear saved credentials (for logout)
  Future<void> clearSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('biometric_user_id');
    await prefs.remove('saved_email');
    await prefs.remove('saved_password');
    await prefs.remove('biometric_setup_timestamp');
    await prefs.setBool('biometric_enabled', false);
  }
  
  ////////// Special authentication for emergency access ///////////////////
  // This allows access to emergency contacts even without full app login
  Future<bool> authenticateForEmergencyAccess() async {
    try {
      // Check if device has biometric future is available
      bool isAvailable = await _localAuth.isDeviceSupported();
      if (!isAvailable) {
        return false;
      }
      
      // Check if biometrics are enrolled
      bool hasFingerprints = await _localAuth.getAvailableBiometrics().then((list) => list.isNotEmpty);
      if (!hasFingerprints) {
        return false;
      }
      
      // Perform biometric authentication with emergency contacts storage
      bool isAuthenticated = await _localAuth.authenticate(
        localizedReason: 'Authenticate to access emergency contacts in case of emergency',
        options: const AuthenticationOptions(
          useErrorDialogs: true,
          stickyAuth: true,
          biometricOnly: true, // Only biometric, no PIN
        ),
      );
      
      return isAuthenticated;
    } catch (e) {
      print('Emergency authentication error: $e');
      return false;
    }
  }
  
  // Check if biometric hardware is available on the device
  Future<bool> isBiometricAvailable() async {
    try {
      return await _localAuth.isDeviceSupported();
    } catch (e) {
      return false;
    }
  }
  
  // Get available biometric types
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }
  
  // Setup biometric access after successful login with user ID
  Future<void> setupBiometricAccess(String userId, String email, String password) async {
    try {
      // Check if biometrics are available
      bool isAvailable = await isBiometricAvailable();
      if (!isAvailable) {
        throw Exception('Biometric authentication not available on this device');
      }
      
      List<BiometricType> availableBiometrics = await getAvailableBiometrics();
      if (availableBiometrics.isEmpty) {
        throw Exception('No biometric methods are set up on this device');
      }
      
      // Test biometric authentication before saving credentials
      bool authSuccess = await authenticateWithBiometrics();
      if (authSuccess) {
        await saveCredentialsForBiometric(userId, email, password);
      } else {
        throw Exception('Biometric authentication test failed');
      }
    } catch (e) {
      print('Setup biometric access error: $e');
      rethrow;
    }
  }
  
  // Get the user ID associated with biometric login
  Future<String?> getBiometricUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('biometric_user_id');
  }
  
  // Check if biometrics are set up for a specific user
  Future<bool> isBiometricSetupForUser(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final savedUserId = prefs.getString('biometric_user_id');
    final biometricEnabled = prefs.getBool('biometric_enabled') ?? false;
    return biometricEnabled && savedUserId == userId;
  }
  
  // Validate and update biometric setup for user switching scenarios
  Future<bool> validateBiometricUserMatch(String currentUserId) async {
    final prefs = await SharedPreferences.getInstance();
    final savedUserId = prefs.getString('biometric_user_id');
    final biometricEnabled = prefs.getBool('biometric_enabled') ?? false;
    
    if (!biometricEnabled || savedUserId == null) {
      return false; // No biometric setup
    }
    
    if (savedUserId != currentUserId) {
      // If different user, will clear old biometric data
      await clearSavedCredentials();
      print('Cleared biometric data for different user account');
      return false;
    }
    
    return true; // If same user, the biometrics are valid
  }
  
  // Get biometric setup information
  Future<Map<String, dynamic>> getBiometricInfo() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'enabled': prefs.getBool('biometric_enabled') ?? false,
      'userId': prefs.getString('biometric_user_id'),
      'email': prefs.getString('saved_email'),
      'setupTimestamp': prefs.getInt('biometric_setup_timestamp'),
    };
  }
}