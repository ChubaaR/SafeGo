import 'package:flutter/material.dart';
import 'emergency_contact_sign_in.dart';
import 'emergency_homepage.dart' as EmergencyHome;
import '../sign_up.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class EmergencyContactSignUp extends StatefulWidget {
  const EmergencyContactSignUp({super.key});

  @override
  EmergencyContactSignUpState createState() => EmergencyContactSignUpState();
}

class EmergencyContactSignUpState extends State<EmergencyContactSignUp> {
  bool _obscureText = true;
  bool _isLoading = false;
  
  // Form controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  
  // Form key for validation
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
  }
  
  
  Future<void> _signUp() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    

    
    setState(() {
      _isLoading = true;
    });
    
    try {
      print('Starting emergency contact sign up process...');
      
      // Check if Firebase is initialized
      if (Firebase.apps.isEmpty) {
        throw Exception('Firebase is not initialized');
      }
      
      // Create user with Firebase Authentication
      print('Creating emergency contact user with email: ${_emailController.text.trim()}');
      
      final FirebaseAuth auth = FirebaseAuth.instance;
      UserCredential? userCredential;
      
      userCredential = await auth.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      
      if (userCredential.user == null) {
        throw Exception('Emergency contact user creation failed: No user returned');
      }
      
      print('Emergency contact user created successfully: ${userCredential.user!.uid}');
      
      // Update user display name
      await userCredential.user!.updateDisplayName(_nameController.text.trim());
      await userCredential.user!.reload();
      
      // Store additional emergency contact data in Firestore
      print('Storing emergency contact data in Firestore...');
      
      final FirebaseFirestore firestore = FirebaseFirestore.instance;
      final String userId = userCredential.user!.uid;
      
      final Map<String, dynamic> emergencyContactData = {
        'email': _emailController.text.trim(),
        'name': _nameController.text.trim(),
        'mobileNumber': _mobileController.text.trim(),
        'accountType': 'emergency_contact',
        'allowShareLiveLocation': true, // Default to true for emergency contacts
        'notifyWhenSafelyArrived': true,
        'shareLiveLocationDuringSOS': true,
        'createdAt': FieldValue.serverTimestamp(),
        'lastSignIn': FieldValue.serverTimestamp(),
      };
      
      await firestore.collection('emergency_contacts').doc(userId).set(emergencyContactData);
      

      
      print('Emergency contact data stored successfully');
      
      // Check if widget is still mounted before navigation
      if (mounted) {
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Emergency contact account created successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        
        // Add a small delay to let the user see the success message
        await Future.delayed(const Duration(milliseconds: 500));
        
        // Navigate to Emergency Contacts page
        if (mounted) {
          print('Attempting to navigate to Emergency Contacts page...');
          try {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const EmergencyHome.HomePage()),
            );
            print('Navigation successful');
          } catch (navError) {
            print('Navigation error: $navError');
            // Try alternative navigation
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const EmergencyHome.HomePage()),
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
          errorMessage = 'An emergency contact account already exists for this email.';
          break;
        case 'invalid-email':
          errorMessage = 'The email address is not valid.';
          break;
        default:
          errorMessage = 'An error occurred during emergency contact registration: ${e.code}';
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
      print('Type casting error during emergency contact sign up: $e');
      
      // Account might have been created successfully despite the error
      if (FirebaseAuth.instance.currentUser != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Emergency contact account created successfully! You can now sign in.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          
          // Navigate to emergency homepage since account was created
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const EmergencyHome.HomePage()),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Emergency contact account creation may have succeeded. Please try signing in.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
          // Navigate to Emergency Contacts page since account creation may have succeeded
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const EmergencyHome.HomePage()),
          );
        }
      }
    } catch (e) {
      print('Unexpected error during emergency contact sign up: $e');
      
      // Check if account was still created despite the error
      if (FirebaseAuth.instance.currentUser != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Emergency contact account created successfully! You can now sign in.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          
          // Navigate to emergency homepage since account was created
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const EmergencyHome.HomePage()),
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
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.lightGreen[100],
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 8),
            children: [

          ////////////////Top Header Text//////////////////////
            const Text(
              'Create an Account',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 5),
            const Text(
              'For Safe Go Emergency Contact',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 20),



            ///////////////Form TextFields//////////////////////
            //////////////Name TextField//////////////////////
            Column(
              children: [
                Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  const Text(
                  'Full Name',
                  textAlign: TextAlign.left,
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
                  controller: _nameController,
                  keyboardType: TextInputType.name,
                  decoration: InputDecoration(
                    labelText: 'Enter your full name',
                    filled: true,
                    fillColor: const Color.fromARGB(166, 231, 231, 231),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),  
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter your full name';
                    }
                    if (value.length < 2) {
                      return 'Name must be at least 2 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                
                //////////////Email TextField//////////////////////
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
                  const SizedBox(width: 150),
                  const Text(
                  'Emergency Contact Email',
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
                    labelText: 'emergency@email.com',
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
                    const SizedBox(width: 100),
                    const Text(
                      'Emergency Contact Phone',
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
                    'Create Emergency Contact Account',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
            ),

            const SizedBox(height: 10),
            
            TextButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const EmergencyContactSignIn()),
                );
              },
              child: const Text(
                'Already have an emergency contact account ? Sign In',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
            ),
            
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 231, 155, 67), // Orange color for emergency theme
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(0),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                elevation: 2,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SignUp()),
                );
              },
              child: const Text(
                'Need a regular user account ? Sign Up',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
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