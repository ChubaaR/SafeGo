import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

void main() async {
  // Initialize Firebase
  await Firebase.initializeApp();
  
  final firestore = FirebaseFirestore.instance;
  
  print('🧹 Starting notification cleanup...');
  
  try {
    // Get all journey notifications
    final QuerySnapshot snapshot = await firestore
        .collection('journey_notifications')
        .orderBy('timestamp', descending: true)
        .get();
    
    print('📊 Found ${snapshot.docs.length} notifications');
    
    if (snapshot.docs.length <= 1) {
      print('✅ Only 1 or fewer notifications found - no cleanup needed');
      return;
    }
    
    // Keep the first (most recent) notification, delete the rest
    final List<DocumentSnapshot> docsToDelete = snapshot.docs.skip(1).toList();
    
    print('🗑️ Will delete ${docsToDelete.length} old notifications, keeping 1 most recent');
    
    // Delete old notifications in batches
    WriteBatch batch = firestore.batch();
    int batchCount = 0;
    
    for (final doc in docsToDelete) {
      batch.delete(doc.reference);
      batchCount++;
      
      // Firestore batch limit is 500 operations
      if (batchCount >= 500) {
        await batch.commit();
        batch = firestore.batch();
        batchCount = 0;
        print('📦 Committed batch of 500 deletions');
      }
    }
    
    // Commit remaining deletions
    if (batchCount > 0) {
      await batch.commit();
      print('📦 Committed final batch of $batchCount deletions');
    }
    
    print('✅ Cleanup complete! Kept 1 notification, deleted ${docsToDelete.length} old ones');
    
    // Show the remaining notification
    final remainingSnapshot = await firestore
        .collection('journey_notifications')
        .orderBy('timestamp', descending: true)
        .limit(1)
        .get();
    
    if (remainingSnapshot.docs.isNotEmpty) {
      final doc = remainingSnapshot.docs.first;
      final data = doc.data() as Map<String, dynamic>;
      print('📝 Remaining notification:');
      print('   ID: ${doc.id}');
      print('   From: ${data['fromUserName'] ?? 'Unknown'}');
      print('   Type: ${data['destination'] ?? 'Unknown'}');
      print('   Time: ${data['startTime'] ?? 'Unknown'}');
    }
    
  } catch (e) {
    print('❌ Error during cleanup: $e');
  }
}