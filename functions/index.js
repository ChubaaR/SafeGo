const functions = require('firebase-functions');
const admin = require('firebase-admin');
const sgMail = require('@sendgrid/mail');

admin.initializeApp();

// Get Firestore and Messaging instances
const db = admin.firestore();
const messaging = admin.messaging();

// Use SendGrid API key stored in functions config: firebase functions:config:set sendgrid.key="SG.xxxxx"
const SENDGRID_API_KEY = functions.config().sendgrid?.key;
if (SENDGRID_API_KEY) {
  sgMail.setApiKey(SENDGRID_API_KEY);
} else {
  console.warn('SendGrid API key not set in functions config. Emails will fail.');
}

exports.sendEmergencyContactEmail = functions.firestore
  .document('users/{uid}/emergency_contacts/{contactId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    if (!data) return null;

    const email = data.email;
    const name = data.name || '';
    const ownerUid = context.params.uid;

    if (!email) {
      console.log('No email for contact, skipping send');
      return null;
    }

    if (!SENDGRID_API_KEY) {
      console.error('SendGrid API key missing; cannot send email');
      return null;
    }

    try {
      // Look up owner's display name / email if needed
      const ownerDoc = await admin.firestore().collection('users').doc(ownerUid).get();
      const ownerData = ownerDoc.exists ? ownerDoc.data() : null;
      const ownerName = ownerData?.displayName || ownerData?.name || 'A SafeGo user';

      const msg = {
        to: email,
        from: functions.config().sendgrid?.from || 'no-reply@safego.example.com',
        subject: `${ownerName} added you as an emergency contact on SafeGo`,
        text: `Hi ${name},\n\n${ownerName} has added you as an emergency contact on SafeGo. You may receive notifications during emergency situations.\n\nIf you don't want to receive these emails, please contact ${ownerName}.\n\nThanks,\nSafeGo Team`,
        html: `<p>Hi ${name},</p><p><strong>${ownerName}</strong> has added you as an emergency contact on <em>SafeGo</em>. You may receive notifications during emergency situations.</p><p>If you don't want to receive these emails, please contact ${ownerName}.</p><p>Thanks,<br/>SafeGo Team</p>`
      };

      const result = await sgMail.send(msg);
      console.log('Email sent', result);
    } catch (err) {
      console.error('Error sending email', err);
    }

    return null;
  });

// Send push notification when a new notification document is created
exports.sendPushNotification = functions.firestore
  .document('notifications/{notificationId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    if (!data) return null;

    const userId = data.userId;
    const type = data.type || '';
    const title = data.title || 'SafeGo Notification';
    const body = data.body || '';
    const contactName = data.relatedContactName || '';

    console.log(`[PUSH_NOTIF] New notification for user: ${userId}, type: ${type}`);

    if (!userId) {
      console.log('[PUSH_NOTIF] No userId found, skipping');
      return null;
    }

    try {
      // If the notification explicitly includes a token field, send directly to that token.
      if (data.token) {
        const explicitToken = data.token;
        console.log(`[PUSH_NOTIF] Explicit token provided, sending to token: ${explicitToken}`);

        const payload = {
          notification: {
            title: title,
            body: body,
          },
          data: {
            type: type,
            contactName: contactName,
            notificationId: context.params.notificationId,
            click_action: 'FLUTTER_NOTIFICATION_CLICK',
          },
        };

        try {
          await messaging.send({ ...payload, token: explicitToken });
          console.log('[PUSH_NOTIF] Push notification sent to explicit token');
        } catch (err) {
          console.error('[PUSH_NOTIF] Error sending to explicit token:', err);
          // Optionally remove invalid token from user's token list if present
          if (err.code === 'messaging/invalid-registration-token' ||
              err.code === 'messaging/registration-token-not-registered') {
            try {
              await db.collection('users')
                .doc(userId)
                .collection('fcm_tokens')
                .where('token', '==', explicitToken)
                .get()
                .then(snapshot => {
                  snapshot.forEach(doc => doc.ref.delete());
                });
            } catch (cleanupErr) {
              console.error('[PUSH_NOTIF] Failed to remove invalid explicit token:', cleanupErr);
            }
          }
        }

        return null;
      }
      // Otherwise, if a topic is provided, send to that topic. This allows
      // companion apps (like the desktop "emersg" helper) to subscribe to a
      // known topic and receive broadcasts for events such as contact_added.
      if (data.topic) {
        const topic = data.topic;
        console.log(`[PUSH_NOTIF] Sending to topic: ${topic}`);

        const payload = {
          notification: {
            title: title,
            body: body,
          },
          data: {
            type: type,
            contactName: contactName,
            notificationId: context.params.notificationId,
            click_action: 'FLUTTER_NOTIFICATION_CLICK',
          },
        };

        try {
          await messaging.send({ ...payload, topic: topic });
          console.log('[PUSH_NOTIF] Push notification sent to topic');
        } catch (err) {
          console.error('[PUSH_NOTIF] Error sending to topic:', err);
        }

        return null;
      }

      // Otherwise, send to all tokens registered under the user document
      const tokensSnapshot = await db.collection('users')
        .doc(userId)
        .collection('fcm_tokens')
        .get();

      if (tokensSnapshot.empty) {
        console.log(`[PUSH_NOTIF] No FCM tokens found for user: ${userId}`);
        return null;
      }

      const tokens = [];
      tokensSnapshot.forEach(doc => {
        const tokenData = doc.data();
        if (tokenData.token) {
          tokens.push(tokenData.token);
        }
      });

      if (tokens.length === 0) {
        console.log('[PUSH_NOTIF] No valid tokens found');
        return null;
      }

      console.log(`[PUSH_NOTIF] Sending to ${tokens.length} device(s)`);

      // Prepare notification payload
      const payload = {
        notification: {
          title: title,
          body: body,
        },
        data: {
          type: type,
          contactName: contactName,
          notificationId: context.params.notificationId,
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
        },
      };

      // Send to all tokens
      const promises = tokens.map(token => {
        return messaging.send({
          ...payload,
          token: token,
        }).catch(error => {
          console.error(`[PUSH_NOTIF] Error sending to token ${token}:`, error);
          // If token is invalid, remove it
          if (error.code === 'messaging/invalid-registration-token' ||
              error.code === 'messaging/registration-token-not-registered') {
            console.log(`[PUSH_NOTIF] Removing invalid token: ${token}`);
            return db.collection('users')
              .doc(userId)
              .collection('fcm_tokens')
              .where('token', '==', token)
              .get()
              .then(snapshot => {
                snapshot.forEach(doc => doc.ref.delete());
              });
          }
          return null;
        });
      });

      await Promise.all(promises);
      console.log('[PUSH_NOTIF] Push notifications sent successfully');
    } catch (error) {
      console.error('[PUSH_NOTIF] Error sending push notification:', error);
    }

    return null;
  });

// Send push notification when a journey notification is created
exports.sendJourneyNotification = functions.firestore
  .document('journey_notifications/{notificationId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    if (!data) return null;

    const toUserId = data.toUserId;
    const type = data.type || 'journey_started';
    const title = data.title || '🚗 Journey Started';
    const body = data.body || '';
    const userName = data.userName || '';

    console.log(`[JOURNEY_NOTIF] New journey notification for user: ${toUserId}, type: ${type}`);

    if (!toUserId) {
      console.log('[JOURNEY_NOTIF] No toUserId found, skipping');
      return null;
    }

    try {
      // Get FCM tokens for the target user
      const tokensSnapshot = await db.collection('users')
        .doc(toUserId)
        .collection('fcm_tokens')
        .get();

      if (tokensSnapshot.empty) {
        console.log(`[JOURNEY_NOTIF] No FCM tokens found for user: ${toUserId}`);
        return null;
      }

      const tokens = [];
      tokensSnapshot.forEach(doc => {
        const tokenData = doc.data();
        if (tokenData.token) {
          tokens.push(tokenData.token);
        }
      });

      if (tokens.length === 0) {
        console.log('[JOURNEY_NOTIF] No valid tokens found');
        return null;
      }

      console.log(`[JOURNEY_NOTIF] Sending to ${tokens.length} device(s)`);

      // Prepare notification payload
      const payload = {
        notification: {
          title: title,
          body: body,
        },
        data: {
          type: type,
          userName: userName,
          notificationId: context.params.notificationId,
          fromUserId: data.fromUserId || '',
          destination: data.destination || '',
          startTime: data.startTime || '',
          currentLocation: data.currentLocation || '',
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
        },
        android: {
          priority: 'high',
          notification: {
            channelId: 'journey_channel',
            priority: 'high',
            defaultSound: true,
            defaultVibrateTimings: true,
          },
        },
        apns: {
          payload: {
            aps: {
              alert: {
                title: title,
                body: body,
              },
              sound: 'default',
              badge: 1,
            },
          },
        },
      };

      // Send to all tokens
      const promises = tokens.map(token => {
        return messaging.send({
          ...payload,
          token: token,
        }).catch(error => {
          console.error(`[JOURNEY_NOTIF] Error sending to token ${token}:`, error);
          // If token is invalid, remove it
          if (error.code === 'messaging/invalid-registration-token' ||
              error.code === 'messaging/registration-token-not-registered') {
            console.log(`[JOURNEY_NOTIF] Removing invalid token: ${token}`);
            return db.collection('users')
              .doc(toUserId)
              .collection('fcm_tokens')
              .where('token', '==', token)
              .get()
              .then(snapshot => {
                snapshot.forEach(doc => doc.ref.delete());
              });
          }
          return null;
        });
      });

      await Promise.all(promises);
      console.log('[JOURNEY_NOTIF] Journey notifications sent successfully');
    } catch (error) {
      console.error('[JOURNEY_NOTIF] Error sending journey notification:', error);
    }

    return null;
  });

// Send push notification when an emergency notification is created
exports.sendEmergencyNotification = functions.firestore
  .document('emergency_notifications/{notificationId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    if (!data) return null;

    const toUserId = data.toUserId;
    const type = data.type || 'sos_alert';
    const title = data.title || '🚨 EMERGENCY SOS ALERT';
    const body = data.body || '';
    const userName = data.userName || '';

    console.log(`[EMERGENCY_NOTIF] New emergency notification for user: ${toUserId}, type: ${type}`);

    if (!toUserId) {
      console.log('[EMERGENCY_NOTIF] No toUserId found, skipping');
      return null;
    }

    try {
      // Get FCM tokens for the target user
      const tokensSnapshot = await db.collection('users')
        .doc(toUserId)
        .collection('fcm_tokens')
        .get();

      if (tokensSnapshot.empty) {
        console.log(`[EMERGENCY_NOTIF] No FCM tokens found for user: ${toUserId}`);
        return null;
      }

      const tokens = [];
      tokensSnapshot.forEach(doc => {
        const tokenData = doc.data();
        if (tokenData.token) {
          tokens.push(tokenData.token);
        }
      });

      if (tokens.length === 0) {
        console.log('[EMERGENCY_NOTIF] No valid tokens found');
        return null;
      }

      console.log(`[EMERGENCY_NOTIF] Sending to ${tokens.length} device(s)`);

      // Prepare high-priority emergency notification payload
      const payload = {
        notification: {
          title: title,
          body: body,
        },
        data: {
          type: type,
          userName: userName,
          notificationId: context.params.notificationId,
          fromUserId: data.fromUserId || '',
          alertTime: data.alertTime || '',
          currentLocation: data.currentLocation || '',
          additionalMessage: data.additionalMessage || '',
          priority: 'critical',
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
        },
        android: {
          priority: 'high',
          notification: {
            channelId: 'emergency_channel',
            priority: 'max',
            defaultSound: true,
            defaultVibrateTimings: true,
            visibility: 'public',
            tag: 'emergency_alert',
          },
        },
        apns: {
          payload: {
            aps: {
              alert: {
                title: title,
                body: body,
              },
              sound: 'default',
              badge: 1,
              'interruption-level': 'critical',
            },
          },
        },
      };

      // Send to all tokens
      const promises = tokens.map(token => {
        return messaging.send({
          ...payload,
          token: token,
        }).catch(error => {
          console.error(`[EMERGENCY_NOTIF] Error sending to token ${token}:`, error);
          // If token is invalid, remove it
          if (error.code === 'messaging/invalid-registration-token' ||
              error.code === 'messaging/registration-token-not-registered') {
            console.log(`[EMERGENCY_NOTIF] Removing invalid token: ${token}`);
            return db.collection('users')
              .doc(toUserId)
              .collection('fcm_tokens')
              .where('token', '==', token)
              .get()
              .then(snapshot => {
                snapshot.forEach(doc => doc.ref.delete());
              });
          }
          return null;
        });
      });

      await Promise.all(promises);
      console.log('[EMERGENCY_NOTIF] Emergency notifications sent successfully');
    } catch (error) {
      console.error('[EMERGENCY_NOTIF] Error sending emergency notification:', error);
    }

    return null;
  });

// Send push notification when a check-in notification is created
exports.sendCheckInNotification = functions.firestore
  .document('checkin_notifications/{notificationId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    if (!data) return null;

    const toUserId = data.toUserId;
    const type = data.type || 'missed_checkin';
    const title = data.title || '⚠️ Missed Check-in Alert';
    const body = data.body || '';
    const userName = data.userName || '';

    console.log(`[CHECKIN_NOTIF] New check-in notification for user: ${toUserId}, type: ${type}`);

    if (!toUserId) {
      console.log('[CHECKIN_NOTIF] No toUserId found, skipping');
      return null;
    }

    try {
      // Get FCM tokens for the target user
      const tokensSnapshot = await db.collection('users')
        .doc(toUserId)
        .collection('fcm_tokens')
        .get();

      if (tokensSnapshot.empty) {
        console.log(`[CHECKIN_NOTIF] No FCM tokens found for user: ${toUserId}`);
        return null;
      }

      const tokens = [];
      tokensSnapshot.forEach(doc => {
        const tokenData = doc.data();
        if (tokenData.token) {
          tokens.push(tokenData.token);
        }
      });

      if (tokens.length === 0) {
        console.log('[CHECKIN_NOTIF] No valid tokens found');
        return null;
      }

      console.log(`[CHECKIN_NOTIF] Sending to ${tokens.length} device(s)`);

      // Prepare high-priority check-in notification payload
      const payload = {
        notification: {
          title: title,
          body: body,
        },
        data: {
          type: type,
          userName: userName,
          notificationId: context.params.notificationId,
          fromUserId: data.fromUserId || '',
          checkInNumber: String(data.checkInNumber || ''),
          missedTime: data.missedTime || '',
          currentLocation: data.currentLocation || '',
          priority: 'high',
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
        },
        android: {
          priority: 'high',
          notification: {
            channelId: 'checkin_channel',
            priority: 'high',
            defaultSound: true,
            defaultVibrateTimings: true,
            tag: 'missed_checkin',
          },
        },
        apns: {
          payload: {
            aps: {
              alert: {
                title: title,
                body: body,
              },
              sound: 'default',
              badge: 1,
              'interruption-level': 'active',
            },
          },
        },
      };

      // Send to all tokens
      const promises = tokens.map(token => {
        return messaging.send({
          ...payload,
          token: token,
        }).catch(error => {
          console.error(`[CHECKIN_NOTIF] Error sending to token ${token}:`, error);
          // If token is invalid, remove it
          if (error.code === 'messaging/invalid-registration-token' ||
              error.code === 'messaging/registration-token-not-registered') {
            console.log(`[CHECKIN_NOTIF] Removing invalid token: ${token}`);
            return db.collection('users')
              .doc(toUserId)
              .collection('fcm_tokens')
              .where('token', '==', token)
              .get()
              .then(snapshot => {
                snapshot.forEach(doc => doc.ref.delete());
              });
          }
          return null;
        });
      });

      await Promise.all(promises);
      console.log('[CHECKIN_NOTIF] Check-in notifications sent successfully');
    } catch (error) {
      console.error('[CHECKIN_NOTIF] Error sending check-in notification:', error);
    }

    return null;
  });

// Send test notification when a test notification document is created
exports.sendTestNotification = functions.firestore
  .document('test_notifications/{notificationId}')
  .onCreate(async (snap, context) => {
    const data = snap.data();
    if (!data) return null;

    const token = data.token; // Direct FCM token
    const type = data.type || 'journey_started_test';
    const title = data.title || '🚗 Test Journey Started';
    const body = data.body || '';
    const userName = data.userName || 'Test User';

    console.log(`[TEST_NOTIF] New test notification to token: ${token ? token.substring(0, 20) + '...' : 'undefined'}`);

    if (!token) {
      console.log('[TEST_NOTIF] No FCM token provided, skipping');
      return null;
    }

    try {
      // Prepare test notification payload
      const payload = {
        notification: {
          title: title,
          body: body,
        },
        data: {
          type: type,
          userName: userName,
          notificationId: context.params.notificationId,
          fromUserId: data.fromUserId || 'test_user',
          destination: data.destination || 'Test Destination',
          startTime: data.startTime || '',
          currentLocation: data.currentLocation || 'Test Location',
          isTestNotification: 'true',
          click_action: 'FLUTTER_NOTIFICATION_CLICK',
        },
        android: {
          priority: 'high',
          notification: {
            channelId: 'journey_channel',
            priority: 'high',
            defaultSound: true,
            defaultVibrateTimings: true,
            tag: 'test_notification',
          },
        },
        apns: {
          payload: {
            aps: {
              alert: {
                title: title,
                body: body,
              },
              sound: 'default',
              badge: 1,
              'interruption-level': 'active',
            },
          },
        },
      };

      console.log(`[TEST_NOTIF] Sending test notification to token: ${token.substring(0, 20)}...`);

      // Send to the specific token
      await messaging.send({
        ...payload,
        token: token,
      });

      console.log('[TEST_NOTIF] Test notification sent successfully');
      
      // Optional: Clean up test notification document after sending
      setTimeout(async () => {
        try {
          await snap.ref.delete();
          console.log('[TEST_NOTIF] Test notification document cleaned up');
        } catch (cleanupError) {
          console.error('[TEST_NOTIF] Error cleaning up test document:', cleanupError);
        }
      }, 5000); // Delete after 5 seconds

    } catch (error) {
      console.error('[TEST_NOTIF] Error sending test notification:', error);
      
      // If token is invalid, log it for debugging
      if (error.code === 'messaging/invalid-registration-token' ||
          error.code === 'messaging/registration-token-not-registered') {
        console.log(`[TEST_NOTIF] Invalid FCM token detected: ${token.substring(0, 20)}...`);
      }
    }

    return null;
  });
