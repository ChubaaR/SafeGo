// lib/biometric_login_page.dart
import 'package:flutter/material.dart';
import 'package:safego/sign_up.dart';
import 'package:safego/homepage.dart';
import 'auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SignIn extends StatefulWidget {
  const SignIn({super.key});

  @override
  SignInState createState() => SignInState();
}

class SignInState extends State<SignIn> {
  final AuthService _authService = AuthService();
  bool _obscureText = true;
  bool _isLoading = false;

  // Form key for validation
  final _formKey = GlobalKey<FormState>();
  
  // Form controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  

  void _biometricLogin() async {
    setState(() => _isLoading = true);
    
    try {
      // First do biometric authentication
      bool biometricSuccess = await _authService.authenticateWithBiometrics();
      
      if (!biometricSuccess) {
        setState(() => _isLoading = false);
        _showCustomPopup('Biometric authentication failed', isError: true);
        return;
      }
      
      // If biometric auth successful, try to sign in with saved credentials
      User? user = await _authService.biometricLoginWithFirebase();
      
      setState(() => _isLoading = false);
      
      if (user != null) {
        // Navigate to HomePage on successful authentication
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomePage()),
        );
      } else {
        // If no saved credentials, show message
        _showCustomPopup('Please sign in with email/password first to enable full biometric login');
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showCustomPopup('Login failed: $e', isError: true);
    }
  }
  
  // Simple sign-in method without Firestore operations to avoid PigeonUserDetails errors
  void _simpleSignIn() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isLoading = true);
      
      try {
        // Authenticate without Firestore operations
        UserCredential userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
        
        // Save credentials for biometric login with user ID
        await _authService.saveCredentialsForBiometric(
          userCredential.user!.uid, // Including user ID for account linking
          _emailController.text.trim(),
          _passwordController.text.trim(),
        );
        
        setState(() => _isLoading = false);
        
        // Upon success, navigate to HomePage
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomePage()),
        );
        
      } on FirebaseAuthException catch (e) {
        setState(() => _isLoading = false);
        String errorMessage;
        
        switch (e.code) {
          case 'user-not-found':
            errorMessage = 'No account found with this email.';
            break;
          case 'wrong-password':
            errorMessage = 'Incorrect password.';
            break;
          case 'invalid-email':
            errorMessage = 'The email address is not valid.';
            break;
          default:
            errorMessage = 'Sign in failed. Please try again.';
        }
        
        _showCustomPopup(errorMessage, isError: true);
        
        } catch (e) {
        setState(() => _isLoading = false);
        _showCustomPopup('Error: ${e.toString()}', isError: true);
      }
    }
  }
  
  void _showCustomPopup(String message, {bool isSuccess = false, bool isError = false}) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isSuccess ? Icons.check_circle : isError ? Icons.error : Icons.info,
                  size: 50,
                  color: isSuccess ? Colors.green : isError ? Colors.red : const Color.fromARGB(255, 255, 225, 190),
                ),
                const SizedBox(height: 15),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color.fromARGB(255, 255, 225, 190),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.of(context, rootNavigator: false).pop();
                  },
                  child: const Text(
                    'OK',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    
    // Auto dismiss after 3 seconds - but only for success messages
    if (isSuccess) {
      Future.delayed(const Duration(seconds: 3), () {
        // Check if the current route is still the dialog we want to dismiss
        if (Navigator.of(context).canPop()) {
          Navigator.of(context, rootNavigator: false).pop();
        }
      });
    }
  }

  void _forgotPassword() async {
    final TextEditingController emailController = TextEditingController();
    
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(25),
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(25),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 15,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_reset,
                  size: 60,
                  color: Color.fromARGB(255, 255, 225, 190),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Reset Password',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Enter your email address and we\'ll send you a password reset link.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 25),
                TextFormField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'Email Address',
                    prefixIcon: const Icon(Icons.email_outlined),
                    filled: true,
                    fillColor: const Color.fromARGB(50, 231, 231, 231),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: const BorderSide(
                        color: Color.fromARGB(255, 255, 225, 190),
                        width: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color.fromARGB(255, 255, 225, 190),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          elevation: 2,
                        ),
                        onPressed: () async {
                          if (emailController.text.trim().isEmpty) {
                            Navigator.of(context).pop();
                            _showCustomPopup('Please enter your email address', isError: true);
                            return;
                          }
                          
                          if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(emailController.text.trim())) {
                            Navigator.of(context).pop();
                            _showCustomPopup('Please enter a valid email address', isError: true);
                            return;
                          }
                          
                          try {
                            await FirebaseAuth.instance.sendPasswordResetEmail(
                              email: emailController.text.trim(),
                            );
                            
                            Navigator.of(context).pop();
                            _showCustomPopup('Password reset link has been sent to your email', isSuccess: true);
                          } on FirebaseAuthException catch (e) {
                            Navigator.of(context).pop();
                            String errorMessage;
                            switch (e.code) {
                              case 'user-not-found':
                                errorMessage = 'No account found with this email.';
                                break;
                              case 'invalid-email':
                                errorMessage = 'The email address is not valid.';
                                break;
                              default:
                                errorMessage = 'Failed to send reset email. Please try again.';
                            }
                            _showCustomPopup(errorMessage, isError: true);
                          } catch (e) {
                            Navigator.of(context).pop();
                            _showCustomPopup('An error occurred. Please try again.', isError: true);
                          }
                        },
                        child: const Text(
                          'Send Link',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _signIn() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isLoading = true);
      
      try {
        // Sign in with Firebase Authentication
        UserCredential userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
        
        // Try to update Firestore, but don't fail if it errors
        try {
          await FirebaseFirestore.instance.collection('users')
              .doc(userCredential.user!.uid)
              .update({
            'lastSignIn': FieldValue.serverTimestamp(),
          });
        } catch (firestoreError) {
          print('Firestore update failed (non-critical): $firestoreError');
          // Continue anyway although authentication was successful
        }
        
        // Save credentials for future biometric login
        try {
          await _authService.saveCredentialsForBiometric(
            userCredential.user!.uid, // Include user ID for account linking
            _emailController.text.trim(),
            _passwordController.text.trim(),
          );
          print('Biometric credentials saved for user: ${userCredential.user!.uid}');
        } catch (biometricError) {
          print('Failed to save biometric credentials (non-critical): $biometricError');
          // Continue anyway although authentication was successful
        }
        
        setState(() => _isLoading = false);
        
        // On success, navigate to HomePage
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HomePage()),
        );
        
      } on FirebaseAuthException catch (e) {
        setState(() => _isLoading = false);
        String errorMessage;
        
        switch (e.code) {
          case 'user-not-found':
            errorMessage = 'No account found with this email.';
            break;
          case 'wrong-password':
            errorMessage = 'Incorrect password.';
            break;
          case 'invalid-email':
            errorMessage = 'The email address is not valid.';
            break;
          default:
            errorMessage = 'Sign in failed. Please try again.';
        }
        
        _showCustomPopup(errorMessage, isError: true);
        
      } on TypeError catch (e) {
        setState(() => _isLoading = false);
        print('PigeonUserDetails type error: $e');
        
        // Offer simple sign-in as alternative
        _showCustomPopup('Connection issue detected. Please try again or use simple sign-in.', isError: true);
        
      } catch (e) {
        setState(() => _isLoading = false);
        print('General sign-in error: $e');
        
        // Check if it's the specific PigeonUserDetails error
        if (e.toString().contains('PigeonUserDetails')) {
          _showCustomPopup('Firebase connection error detected. Please try again.', isError: true);
        } else {
          _showCustomPopup('Error: ${e.toString()}', isError: true);
        }
      }
    }
  }
  
  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
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
            const Text(
              'Hi, Welcome Back!👋',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'Hi Again! We Missed you!',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 20),

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
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color.fromARGB(255, 255, 225, 190),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                onPressed: _isLoading ? null : _biometricLogin,
                child: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.black,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'Sign In Via Biometrics',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
              ),
            const SizedBox(height: 20),
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
                  'Sign In with Email',
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
                    return null;
                  },
                ),
                const SizedBox(height: 5),
                Row(
                mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: _forgotPassword,
                      child: const Text(
                        'Forgot Password ?',
                        textAlign: TextAlign.left,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ],
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
              onPressed: _isLoading ? null : _signIn,
              child: _isLoading 
                ? const CircularProgressIndicator(color: Colors.black)
                : const Text(
                    'Sign In',
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
                  MaterialPageRoute(builder: (context) => const SignUp()),
                );
              },
              child: const Text(
                'Don’t have an account ? Sign Up',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
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
