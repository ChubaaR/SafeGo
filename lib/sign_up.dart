// lib/biometric_login_page.dart
import 'package:flutter/material.dart';
import 'package:safego/sign_in.dart';
import 'auth_service.dart';
import 'package:safego/homepage.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:safego/Emergency%20Contacts/emergency_contact_sign_up.dart';


class SignUp extends StatefulWidget {
  const SignUp({super.key});

  @override
  SignUpState createState() => SignUpState();
}

class SignUpState extends State<SignUp> {
  final AuthService _authService = AuthService();
  bool _obscureText = true;
  bool _isLoading = false;
  bool _biometricRegistered = false;
  bool _isBiometricAvailable = false;
  
  // Form controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  
  // Form key for validation
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _checkBiometricAvailability();
  }
  
  Future<void> _checkBiometricAvailability() async {
    bool isAvailable = await _authService.isBiometricAvailable();
    List availableBiometrics = await _authService.getAvailableBiometrics();
    
    setState(() {
      _isBiometricAvailable = isAvailable && availableBiometrics.isNotEmpty;
    });
  }
  
  Future<void> _registerBiometrics() async {
    if (!_isBiometricAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Biometric authentication is not available on this device'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    try {
      bool success = await _authService.authenticateWithBiometrics();
      if (success) {
        setState(() {
          _biometricRegistered = true;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Biometrics registered successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Biometric registration failed. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error during biometric registration: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  
  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    
    // Check if biometrics are registered (optional but recommended)
    if (_isBiometricAvailable && !_biometricRegistered) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please register your biometrics for enhanced security'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      // Allow user to continue without biometrics, but show warning
    }
    
    setState(() {
      _isLoading = true;
    });
    
    try {
      print('Starting sign up process...');
      
      // Check if Firebase is initialized
      if (Firebase.apps.isEmpty) {
        throw Exception('Firebase is not initialized');
      }
      
      // Create user with Firebase Authentication
      print('Creating user with email: ${_emailController.text.trim()}');
      
      final FirebaseAuth auth = FirebaseAuth.instance;
      UserCredential? userCredential;
      
      userCredential = await auth.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      
      if (userCredential.user == null) {
        throw Exception('User creation failed: No user returned');
      }
      
      print('User created successfully: ${userCredential.user!.uid}');
      
      // Store additional user data in Firestore
      print('Storing user data in Firestore...');
      
      final FirebaseFirestore firestore = FirebaseFirestore.instance;
      final String userId = userCredential.user!.uid;
      
      final Map<String, dynamic> userData = {
        'email': _emailController.text.trim(),
        'mobileNumber': _mobileController.text.trim(),
        'biometricRegistered': _biometricRegistered,
        'biometricAvailable': _isBiometricAvailable,
        'createdAt': FieldValue.serverTimestamp(),
        'lastSignIn': FieldValue.serverTimestamp(),
      };
      
      await firestore.collection('users').doc(userId).set(userData);
      
      // If biometrics were registered, save credentials for future biometric login
      if (_biometricRegistered) {
        try {
          await _authService.setupBiometricAccess(
            userId, // Pass the Firebase user ID
            _emailController.text.trim(),
            _passwordController.text.trim(),
          );
          print('Biometric access setup successfully for user: $userId');
        } catch (e) {
          print('Failed to setup biometric access: $e');
          // Continue with normal registration even if biometric setup fails
        }
      }
      
      print('User data stored successfully');
      
      // Check if widget is still mounted before navigation
      if (mounted) {
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account created successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        
        // Add a small delay to let the user see the success message
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Navigate to HomePage
        if (mounted) {
          print('Attempting to navigate to HomePage...');
          try {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const HomePage()),
            );
            print('Navigation successful');
          } catch (navError) {
            print('Navigation error: $navError');
            // Try alternative navigation
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const HomePage()),
              (Route<dynamic> route) => false,
            );
          }
        }
      }
      
    } on FirebaseAuthException catch (e) {
      String errorMessage;
      switch (e.code) {
        case 'weak-password':
          errorMessage = 'The password provided is too weak.';
          break;
        case 'email-already-in-use':
          errorMessage = 'An account already exists for this email.';
          break;
        case 'invalid-email':
          errorMessage = 'The email address is not valid.';
          break;
        default:
          errorMessage = 'An error occurred during registration: ${e.code}';
      }
      
      print('FirebaseAuthException: ${e.code} - ${e.message}');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red,
          ),
        );
      }
    } on TypeError catch (e) {
      print('Type casting error during sign up: $e');
      
      // Account might have been created successfully despite the error
      if (FirebaseAuth.instance.currentUser != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created successfully! You can now sign in.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          
          // Navigate to sign-in page since account was created
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const SignIn()),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account creation may have succeeded. Please try signing in.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
          // Navigate to HomePage since account creation may have succeeded
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const HomePage()),
          );
        }
      }
    } catch (e) {
      print('Unexpected error during sign up: $e');
      
      // Check if account was still created despite the error
      if (FirebaseAuth.instance.currentUser != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created successfully! You can now sign in.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          
          // Navigate to sign-in page since account was created
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const HomePage()),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('An error occurred: ${e.toString()}'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
        }
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }
  
  @override
  void dispose() {
    _emailController.dispose();
    _mobileController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 8),
            children: [

          ////////////////Top Header Text//////////////////////
            const Text(
              'Create an account',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Safe Go..',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 20),

            ////////////////Face and Fingerprint Image//////////////////////

            Column (
              mainAxisAlignment: MainAxisAlignment.center,
                children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                  Image.asset(
                    'assets/face.png',
                    height: 150,
                  ),
                  const SizedBox(width: 30),
                  Image.asset(
                    'assets/fingerprint.png',
                    height: 150,
                  ),
                  ],
                ),
                ],
            ),
            const SizedBox(height: 20),
            const Text(
              'Scan your face/fingerprint for verification',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 10),
            

            ///////////////Scan to Register Biometrics Button//////////////////////
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _biometricRegistered 
                    ? const Color.fromARGB(255, 144, 238, 144) // Light green when registered
                    : const Color.fromARGB(255, 255, 225, 190), // Original color
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onPressed: _isBiometricAvailable && !_biometricRegistered 
                  ? _registerBiometrics 
                  : null,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_biometricRegistered)
                      const Icon(Icons.check_circle, color: Colors.green, size: 24),
                    if (_biometricRegistered) const SizedBox(width: 8),
                    Text(
                      _biometricRegistered 
                        ? 'Biometrics Registered ✓' 
                        : _isBiometricAvailable 
                          ? 'Scan To Register Biometrics'
                          : 'Biometrics Not Available',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: _biometricRegistered ? 16 : 20,
                        fontWeight: FontWeight.bold,
                        color: _isBiometricAvailable ? Colors.black : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),

            ///////////////Email, Mobile and Password TextFields//////////////////////
            //////////////Email TextField//////////////////////
            Column(
              children: [
                Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                  'Email',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                  const SizedBox(width: 200),
                  const Text(
                  'Sign Up with Email',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                ],
                ),
                const SizedBox(height: 5),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'user@gmail.com',
                    filled: true,
                    fillColor: const Color.fromARGB(166, 231, 231, 231),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),  
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter your email';
                    }
                    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
                      return 'Please enter a valid email';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                
                //////////////Mobile TextField//////////////////////
                Row(
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
                    const SizedBox(width: 95),
                    const Text(
                      'Sign Up with Phone Number',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                TextFormField(
                  controller: _mobileController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: 'Enter your number',
                    filled: true,
                    fillColor: const Color.fromARGB(166, 231, 231, 231),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),  
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter your mobile number';
                    }
                    if (value.length < 10) {
                      return 'Please enter a valid mobile number';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),

              //////////////Password TextField//////////////////////
                Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  const Text(
                  'Password',
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                ],
                ),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscureText,
                  decoration: InputDecoration(
                    labelText: 'Enter your password',
                    filled: true,
                    fillColor: const Color.fromARGB(166, 231, 231, 231),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureText ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureText = !_obscureText;
                        });
                      },
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter your password';
                    }
                    if (value.length < 6) {
                      return 'Password must be at least 6 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),

              //////////////Confirm Password TextField//////////////////////
                Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  const Text(
                  'Confirm Password',
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  ),
                ],
                ),
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: _obscureText,
                  decoration: InputDecoration(
                    labelText: 'Confirm your password',
                    filled: true,
                    fillColor: const Color.fromARGB(166, 231, 231, 231),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureText ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscureText = !_obscureText;
                        });
                      },
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please confirm your password';
                    }
                    if (value != _passwordController.text) {
                      return 'Passwords do not match';
                    }
                    return null;
                  },
                ),
              ],
            ),
          
            const SizedBox(height: 20),            
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 255, 225, 190), // F9E2BC color
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: _isLoading ? null : _signUp,
              child: _isLoading 
                ? const CircularProgressIndicator(color: Colors.black)
                : const Text(
                    'Sign Up',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
            ),

            const SizedBox(height: 20),
            
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SignIn()),
                );
              },
              child: const Text(
                'Already have an account ? Sign In',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
            ),

            const SizedBox(height: 10),
            
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 231, 155, 67), // Orange color for emergency
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(0),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
                elevation: 2,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const EmergencyContactSignUp()),
                );
              },
              child: const Text(
                'Emergency Contact',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }
}
