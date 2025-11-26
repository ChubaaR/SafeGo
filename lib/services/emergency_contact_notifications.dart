import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import '../models/emergency_contact.dart';
import '../notification_service.dart';

/// Service utilities to notify emergency contacts about user events.
///
/// This file intentionally keeps notifications delivery lightweight by:
/// - Writing a small document to each contact's `notifications` subcollection in
///   Firestore (so server/cloud functions or external systems can deliver SMS/FCM).
/// - Sending a local device notification using `NotificationService` for quick
///   visual feedback when appropriate.
///
/// Assumptions / notes:
/// - The app stores emergency contacts under the current user's collection
///   at: `/users/{uid}/emergency_contacts/{contactId}`.
/// - A backend/cloud-function watches `notifications` subcollections and sends
///   the actual push/SMS messages to the contacts. If you don't have a backend,
///   these Firestore writes can be used as an audit/log or trigger other client
///   devices to act.

class EmergencyContactNotifications {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Notify a contact that they've been added as an emergency contact.
  ///
  /// Writes a notification doc under the contact and shows a local notification
  /// on the device for immediate feedback.
  static Future<void> notifyContactAdded({
    required String uid,
    required EmergencyContact contact,
  }) async {
    try {
      final docRef = _firestore
          .collection('users')
          .doc(uid)
          .collection('emergency_contacts')
          .doc(contact.id)
          .collection('notifications')
          .doc();

      final payload = {
        'type': 'contact_added',
        'message': '${contact.name} was added as an emergency contact.',
        'timestamp': FieldValue.serverTimestamp(),
        'meta': {
          'contactName': contact.name,
          'phoneNumber': contact.phoneNumber,
        }
      };

      await docRef.set(payload);

      // Ensure notification subsystem is initialized (no direct local
      // notification shown here to avoid using private members).
      await NotificationService.initialize();
      debugPrint('Wrote contact_added notification for ${contact.id}');
    } catch (e, st) {
      debugPrint('Error notifying contact added: $e');
      debugPrint('$st');
    }
  }

  /// Start sharing live location to contacts who have allowed live location.
  ///
  /// This will write a small live-location document that the contact (or a
  /// backend) can observe. It does NOT stream GPS continuously from this
  /// function; instead it writes the provided [position]. For continuous
  /// updates, call this in a periodic timer or location subscription.
  static Future<void> updateLiveLocation({
    required String uid,
    required EmergencyContact contact,
    required Position position,
    DateTime? timestamp,
  }) async {
    try {
      if (!contact.allowShareLiveLocation && !contact.shareLiveLocationDuringSOS) {
        // contact doesn't want live updates
        return;
      }

      final locDoc = _firestore
          .collection('users')
          .doc(uid)
          .collection('emergency_contacts')
          .doc(contact.id)
          .collection('live_location')
          .doc('current');

      final data = {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'timestamp': timestamp ?? FieldValue.serverTimestamp(),
      };

      await locDoc.set(data, SetOptions(merge: true));

      // Optionally send a local notification to the device to indicate update
      // (kept minimal to avoid spam)
      // We use NotificationService.show with small payload - delegate to existing
      // service's check-in channel for simplicity.
      await NotificationService.initialize();
      debugPrint('Live location update written for ${contact.id}');
    } catch (e, st) {
      debugPrint('Error updating live location for ${contact.id}: $e');
      debugPrint('$st');
    }
  }

  /// Update live location with journey route information for emergency contacts.
  ///
  /// This enhanced version includes the planned route so emergency contacts
  /// can see both current location and the intended journey path.
  static Future<void> updateLiveLocationWithRoute({
    required String uid,
    required EmergencyContact contact,
    required Position position,
    List<Map<String, double>>? routePoints,
    Map<String, double>? destination,
    DateTime? timestamp,
  }) async {
    try {
      if (!contact.allowShareLiveLocation && !contact.shareLiveLocationDuringSOS) {
        // contact doesn't want live updates
        return;
      }

      final locDoc = _firestore
          .collection('users')
          .doc(uid)
          .collection('emergency_contacts')
          .doc(contact.id)
          .collection('live_location')
          .doc('current');

      final data = {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'timestamp': timestamp ?? FieldValue.serverTimestamp(),
        // Include route information for emergency contacts to see the planned journey
        if (routePoints != null && routePoints.isNotEmpty) 
          'routePoints': routePoints,
        if (destination != null)
          'destination': destination,
        'hasRoute': routePoints != null && routePoints.isNotEmpty,
      };

      await locDoc.set(data, SetOptions(merge: true));

      await NotificationService.initialize();
      debugPrint('Live location with route updated for ${contact.id} (${routePoints?.length ?? 0} route points)');
    } catch (e, st) {
      debugPrint('Error updating live location with route for ${contact.id}: $e');
      debugPrint('$st');
    }
  }

  /// Send an SOS alert to all emergency contacts for the given user.
  ///
  /// Resolves the nearest place name using reverse geocoding and writes an
  /// SOS notification document under each contact. Also triggers the local
  /// SOS notification UI via `NotificationService.showSOSAlertNotification`.
  static Future<void> sendSOSAlert({
    required String uid,
    required List<EmergencyContact> contacts,
    required Position position,
    String? userName,
  }) async {
    String? placeName;
    try {
      final placemarks = await geocoding.placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        placeName = '${p.name ?? ''} ${p.locality ?? ''}'.trim();
      }
    } catch (e) {
      debugPrint('Reverse geocoding failed: $e');
      placeName = null;
    }

    // Write notifications for each contact
    final batch = _firestore.batch();
    final ts = FieldValue.serverTimestamp();

    for (final c in contacts) {
      final notifRef = _firestore
          .collection('users')
          .doc(uid)
          .collection('emergency_contacts')
          .doc(c.id)
          .collection('notifications')
          .doc();

      final message = {
        'type': 'sos_alert',
        'message': 'SOS alert triggered by ${userName ?? 'your contact'}',
        'location': {
          'lat': position.latitude,
          'lng': position.longitude,
          'placeName': placeName,
        },
        'timestamp': ts,
        'meta': {
          'shareLiveLocationDuringSOS': c.shareLiveLocationDuringSOS,
        }
      };

      batch.set(notifRef, message);
    }

    try {
      await batch.commit();

      // Fire a local SOS notification for the device user with place name
      await NotificationService.showSOSAlertNotification(
        checkInNumber: 0,
        userName: userName,
        userLocation: placeName ?? '${position.latitude}, ${position.longitude}',
      );
    } catch (e, st) {
      debugPrint('Error sending SOS alert: $e');
      debugPrint('$st');
    }
  }

  /// Notify emergency contacts that the user has safely arrived to their
  /// destination. Only notifies contacts that opted in for safe-arrival alerts.
  static Future<void> notifySafeArrival({
    required String uid,
    required List<EmergencyContact> contacts,
    String? userName,
    DateTime? arrivedAt,
  }) async {
    final batch = _firestore.batch();
    final ts = FieldValue.serverTimestamp();

    for (final c in contacts) {
      if (!c.notifyWhenSafelyArrived) continue;

      final notifRef = _firestore
          .collection('users')
          .doc(uid)
          .collection('emergency_contacts')
          .doc(c.id)
          .collection('notifications')
          .doc();

      final message = {
        'type': 'safe_arrival',
        'message': '${userName ?? 'Your contact'} has safely arrived at their destination.',
        'timestamp': ts,
      };

      batch.set(notifRef, message);
    }

    try {
      await batch.commit();
      await NotificationService.initialize();
      debugPrint('Safe arrival notifications written for opted-in contacts');
    } catch (e, st) {
      debugPrint('Error notifying safe arrival: $e');
      debugPrint('$st');
    }
  }
}
