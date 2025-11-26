import 'package:flutter/material.dart';

class NotificationsManager {
  NotificationsManager._();
  static final NotificationsManager instance = NotificationsManager._();
  final List<NotificationEntry> _notifications = [];

  List<NotificationEntry> get notifications => List.unmodifiable(_notifications.reversed);

  void add(String title, {String? body}) {
    _notifications.add(NotificationEntry(title: title, body: body ?? '', timestamp: DateTime.now()));
  }

  void clear() => _notifications.clear();
}

class NotificationEntry {
  final String title;
  final String body;
  final DateTime timestamp;
  NotificationEntry({required this.title, required this.body, required this.timestamp});
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  @override
  Widget build(BuildContext context) {
    final items = NotificationsManager.instance.notifications;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190),
        foregroundColor: Colors.black,
        centerTitle: true,
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() {
                  NotificationsManager.instance.clear();
                });
              },
              child: const Text('Clear', style: TextStyle(color: Colors.black)),
            )
        ],
      ),
      body: items.isEmpty
          ? const Center(child: Text('No notifications', style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, idx) {
                final n = items[idx];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: ListTile(
                    leading: const Icon(Icons.check_circle, color: Colors.green),
                    title: Text(n.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: n.body.isNotEmpty ? Text(n.body) : null,
                    trailing: Text(
                      _formatTime(n.timestamp),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                );
              },
            ),
    );
  }

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}
