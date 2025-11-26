import 'package:flutter/material.dart';

class SplashScreen extends StatefulWidget {
  final ImageProvider image;
  final Duration duration;
  final Widget nextScreen;

  const SplashScreen({
    super.key,
    required this.image,
    required this.duration,
    required this.nextScreen,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _navigateToNextScreen();
  }

  void _navigateToNextScreen() {
    Future.delayed(widget.duration, () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => widget.nextScreen),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          image: DecorationImage(
            image: widget.image,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}