import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ConvertLatLong extends StatefulWidget {
  const ConvertLatLong({super.key});

  @override
  State<ConvertLatLong> createState() => _ConvertLatLongState();
}

class _ConvertLatLongState extends State<ConvertLatLong> {
  final TextEditingController latitudeController = TextEditingController();
  final TextEditingController longitudeController = TextEditingController();
  String stAddress = '';

  Future<void> getAddress(double lat, double lon) async {
    final url =
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json';

    final response = await http.get(
      Uri.parse(url),
      headers: {
        // REQUIRED by Nominatim usage policy
        'User-Agent': 'MyFlutterApp/1.0 (myemail@example.com)'
      },
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      setState(() {
        stAddress = data['display_name'] ?? 'No address found';
      });
    } else {
      setState(() {
        stAddress = 'Error: ${response.statusCode}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("OSM Reverse Geocoding")),
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          children: [
            TextField(
              controller: latitudeController,
              decoration: const InputDecoration(hintText: 'Latitude'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: longitudeController,
              decoration: const InputDecoration(hintText: 'Longitude'),
              keyboardType: TextInputType.number,
            ),
            ElevatedButton(
              onPressed: () {
                final lat = double.tryParse(latitudeController.text);
                final lon = double.tryParse(longitudeController.text);
                if (lat != null && lon != null) {
                  getAddress(lat, lon);
                } else {
                  setState(() => stAddress = "Invalid input");
                }
              },
              child: const Text("Convert"),
            ),
            const SizedBox(height: 20),
            Text(stAddress),
            const Spacer(),
            const Text("© OpenStreetMap contributors",
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
