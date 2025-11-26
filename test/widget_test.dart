// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safego/sign_in.dart';

void main() {
  testWidgets('Biometric login test', (WidgetTester tester) async {
  // Build our app and trigger a frame. Wrap SignIn in MaterialApp to provide
  // Directionality and ScaffoldMessenger for widgets that expect them.
  await tester.pumpWidget(MaterialApp(home: SignIn()));

  // Verify that the login button is present.
  expect(find.text('Sign In Via Biometrics'), findsOneWidget);
    expect(find.text('Welcome!'), findsNothing);

  // Tap the login button and trigger a frame.
  await tester.tap(find.text('Sign In Via Biometrics'));
    await tester.pump();

  });
}
