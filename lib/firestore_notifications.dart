import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> sendNotificationToUser({
  required String targetUid,
  required String title,
  required String body,
  String? type,
  String? senderUserId,
}) async {
  final notifData = {
    'title': title,
    'body': body,
    'type': type ?? 'generic',
    'read': false,
    'userId': targetUid,
    if (senderUserId != null) 'senderUserId': senderUserId,
    'createdAt': FieldValue.serverTimestamp(),
  };

  final firestore = FirebaseFirestore.instance;

  // Write to top-level notifications collection to trigger Cloud Functions
  await firestore.collection('notifications').add(notifData);

  // Also persist under the recipient user's notifications subcollection
  await firestore.collection('users').doc(targetUid).collection('notifications').add(notifData);
}
