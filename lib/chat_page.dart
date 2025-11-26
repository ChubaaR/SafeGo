import 'package:flutter/material.dart';
import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter_gemini/flutter_gemini.dart';
import 'package:safego/homepage.dart';
import 'package:safego/myProfile.dart';
import 'package:safego/sos.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
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

class _ChatPageState extends State<ChatPage> {
  final ChatUser _currentUser = ChatUser(id: '1', firstName: 'You');
  final ChatUser _geminiUser = ChatUser(id: '2', firstName: 'Gemini');

  final List<ChatMessage> _messages = [];
  Gemini? gemini;
  // FAQ quick-reply options (user requested replacements)
  final List<String> _faqOptions = [
    'What is SafeGo?',
    'How do I use SOS?',
    'What happens when I miss a check-in?',
    'Does SafeGo work without an internet connection?',
  ];

  // Canned answers for the FAQs so the app can reply even when Gemini is
  // not initialized or offline. Keys are normalized to lowercase.
  final Map<String, String> _faqAnswers = {
    'what is safego?':
        'SafeGo is a personal safety app that helps you share your journey, ' 
        'manage emergency contacts, and send quick SOS alerts. It also supports ' 
        'scheduled check-ins so trusted contacts can be notified if you don\'t respond.',

    'how do i use sos?':
        'To use SOS: tap the large SOS button on the main screens. ' 
        'Tapping it will trigger an emergency alert that notifies your ' 
        'saved emergency contacts and ' 
        'sends your location information so they can find you. Make sure your ' 
        'emergency contacts are set up in the Emergency Contacts section.',

    'what happens when i miss a check-in?':
        'If you miss a scheduled check-in, SafeGo\'s notification service ' 
        'will detect the missed response and notify your emergency contacts. ' 
        'This lets your trusted contacts know you may need help and provides ' 
        'them with your last known location if available.',

    'does safego work without an internet connection?':
        'Some features of SafeGo require an internet connection (for example, ' 
        'sending SOS alerts to contacts and syncing check-in status via Firebase). ' 
        'Other features, like viewing locally cached data, may still work offline, ' 
        'but for full functionality an internet connection is recommended.',
  };

  // Try fetching an FAQ answer from Firestore by matching the question text.
  // If Firestore is not available, or no document matches, return null.
  Future<String?> _fetchFaqAnswerFromFirestore(String question) async {
    try {
      final col = FirebaseFirestore.instance.collection('faqs');
      final query = await col.where('question', isEqualTo: question).limit(1).get();
      if (query.docs.isNotEmpty) {
        final data = query.docs.first.data();
        return data['answer'] as String?;
      }
    } catch (_) {
      // ignore Firestore errors and fall back to local answers
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Color.fromARGB(255, 255, 225, 190),
        elevation: 8,
        shadowColor: Colors.black.withOpacity(0.4), // Shadow color
        centerTitle: true,
        title: const Text(
          'SafeGo Chat',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
      ),
      body: Column(
        children: [
          // FAQ quick replies area
          Container(
            width: double.infinity,
            color: Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _faqOptions.map((option) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: OutlinedButton(
                      onPressed: () async {
                        // Create a ChatMessage for the selected FAQ and send it
                        final faqMessage = ChatMessage(
                          user: _currentUser,
                          createdAt: DateTime.now(),
                          text: option,
                        );
                        // Insert the user message first
                        setState(() {
                          _messages.insert(0, faqMessage);
                        });

                        // Try Firestore first
                        final normalized = option.trim();
                        String? answer = await _fetchFaqAnswerFromFirestore(normalized);
                        // Fallback to local canned answers
                        answer ??= _faqAnswers[normalized.toLowerCase()];

                        final reply = answer ??
                            'Sorry, I don\'t have an answer for that right now.';

                        setState(() {
                          _messages.insert(
                            0,
                            ChatMessage(
                              user: _geminiUser,
                              createdAt: DateTime.now(),
                              text: reply,
                            ),
                          );
                        });
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFBF00EF)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: Text(option, style: const TextStyle(color: Colors.black)),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // Chat area
          Expanded(
            child: DashChat(
              currentUser: _currentUser,
              messageOptions: const MessageOptions(
                currentUserContainerColor: Color(0xFFBF00EF),
                containerColor: Color(0xFFFFADFF),
                textColor: Colors.black,
              ),
              inputOptions: const InputOptions(
                inputDecoration: InputDecoration(
                  filled: true,
                  fillColor: Color.fromARGB(255, 255, 219, 178),
                  hintText: 'Enter a message...',
                  hintStyle: TextStyle(color: Color.fromARGB(255, 129, 129, 129)),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20.0)),
                    borderSide: BorderSide(
                      color: Colors.white,
                      width: 2.0,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20.0)),
                    borderSide: BorderSide(
                      color: Colors.white,
                      width: 1.0,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20.0)),
                    borderSide: BorderSide(
                      color: Colors.white,
                      width: 1.0,
                    ),
                  ),
                ),
              ),
              onSend: (ChatMessage m) {
                getGeminiResponse(m);
              },
              messages: _messages,
            ),
          ),
        ],
      ),
      backgroundColor: Colors.white,

      // Bottom navigation bar 
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
          backgroundColor: Color.fromARGB(255, 255, 225, 190),
          selectedItemColor: Colors.black,
          unselectedItemColor: Colors.grey,
          currentIndex: 0, // Chat/Home tab will be selected by default here
          onTap: (index) {
            if (index == 0) {
              // Navigate to Home
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const HomePage()),
              );
            } else if (index == 1) {
              // Navigate to Profile
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const MyProfile()),
              );
            }
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

      // Floating SOS Button (same as MyProfile)
      floatingActionButton: SizedBox(
        width: 80,
        height: 80,
        child: FloatingActionButton(
          onPressed: () {
            EmergencyAlert.show(context);
          },
          backgroundColor: Colors.white,
          heroTag: "chatSosButton", // Unique hero tag
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

  Future<void> getGeminiResponse(ChatMessage m) async {
    setState(() {
      // Insert user message at the start so newest messages appear at the top
      _messages.insert(0, m);
    });

    try {
      // Resolve the Gemini instance lazily. Accessing `Gemini.instance` can
      // throw a LateInitializationError if the package wasn't initialized.
      final g = gemini ??= Gemini.instance;
      final response = await g.text(m.text);

      if (response != null && response.output != null) {
        setState(() {
          // Insert bot response at the start
          _messages.insert(
            0,
            ChatMessage(
              user: _geminiUser,
              createdAt: DateTime.now(),
              text: response.output!,
            ),
          );
        });
      }
    } catch (e) {

      final errString = e.toString();
      final isLateInit = errString.contains('LateInitializationError') ||
          errString.contains('Late initialization error');

      if (isLateInit) {
        // Try to provide a canned, factual answer for known FAQ options
        final normalized = m.text.trim().toLowerCase();
        final canned = _faqAnswers[normalized];

        final reply = canned ??
            'Gemini SDK is not initialized. Make sure you call the package initialization (for example, Gemini.initialize(...)) before using it.';

        setState(() {
          // Insert the reply from the app (bot) at the top
          _messages.insert(
            0,
            ChatMessage(
              user: _geminiUser,
              createdAt: DateTime.now(),
              text: reply,
            ),
          );
        });
      } else {
        final msg = 'Something went wrong: $e';
        setState(() {
          _messages.insert(
            0,
            ChatMessage(
              user: _geminiUser,
              createdAt: DateTime.now(),
              text: msg,
            ),
          );
        });
      }
    }
  }
}

///////////////End BottomNavigationBar////////////////////////
