import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'models/saved_location.dart';
import 'services/saved_locations_service.dart';
import 'services/user_preferences_service.dart';
import 'package:safego/face_scan.dart';
import 'package:safego/sign_in.dart';
import 'package:safego/myProfile.dart';
import 'package:safego/sos.dart';
import 'package:auto_size_text/auto_size_text.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final MapController mapController = MapController();
  final TextEditingController destinationController = TextEditingController();
  LatLng? currentLocation;
  // Services
  final UserPreferencesService _userPreferencesService = UserPreferencesService();
  final SavedLocationsService _savedLocationsService = SavedLocationsService();

  // UI & state
  String currentAddress = 'Getting your location...';
  bool isLoading = false;
  bool isSearching = false;
  List<Map<String, dynamic>> locationSuggestions = [];
  OverlayEntry? _overlayEntry;
  final LayerLink _layerLink = LayerLink();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounceTimer;

  // Destination selection
  LatLng? selectedDestinationCoords;
  String? selectedDestinationName;
  String selectedTransportMode = 'driving';

  // Quick locations
  final TextEditingController location1Controller = TextEditingController();
  final TextEditingController location2Controller = TextEditingController();
  SavedLocation? selectedLocation1;
  SavedLocation? selectedLocation2;
  bool _isLocation1Default = false;
  bool _isLocation2Default = false;

  // Saved locations cache
  List<SavedLocation> savedLocations = [];

  @override
  void initState() {
    super.initState();
    // Load initial data
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    // Get current location and address (non-blocking)
    _getCurrentLocation().catchError((e) {
      print('Initial location fetch failed: $e');
      if (mounted) {
        setState(() {
          currentAddress = 'Tap refresh to get location';
        });
      }
    });

    // Load saved locations and quick access/defaults
    try {
      savedLocations = await _savedLocationsService.getSavedLocations();

      // Get quick access (home/office) from saved locations
      final quick = await _savedLocationsService.getQuickAccessLocations();
      selectedLocation1 = quick['home'];
      selectedLocation2 = quick['office'];

      // Get defaults from preferences service
      final defaults = await _userPreferencesService.getDefaultLocations();
      if (defaults['home'] != null) {
        _isLocation1Default = true;
        // if we don't have a full saved location, use the preference stub
        selectedLocation1 ??= defaults['home'];
      }
      if (defaults['work'] != null) {
        _isLocation2Default = true;
        selectedLocation2 ??= defaults['work'];
      }
    } catch (e) {
      print('Error loading initial data: $e');
    }

    if (mounted) setState(() {});
  }

  // Show dialog to save a location after reverse geocoding or long press
  Future<void> _showLocationSaveDialog({required LatLng coordinates, required String address}) async {
    final nameController = TextEditingController(text: address);
    String selectedType = 'home';

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          'Save Location',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Name',
                labelStyle: const TextStyle(color: Colors.black54),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.grey),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color.fromARGB(255, 76, 175, 80), width: 2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: selectedType,
              items: const [
                DropdownMenuItem(value: 'home', child: Text('Home')),
                DropdownMenuItem(value: 'office', child: Text('Work')),
              ],
              onChanged: (v) => selectedType = v ?? 'home',
              decoration: InputDecoration(
                labelText: 'Type',
                labelStyle: const TextStyle(color: Colors.black54),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.grey),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color.fromARGB(255, 76, 175, 80), width: 2),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: Colors.grey[600],
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color.fromARGB(255, 76, 175, 80),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Save',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (result == true) {
      final id = await _savedLocationsService.saveLocation(
        name: nameController.text.trim(),
        address: address,
        latitude: coordinates.latitude,
        longitude: coordinates.longitude,
        type: selectedType,
      );

      if (id != null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Location saved'), backgroundColor: Colors.green));
        // Refresh saved locations
        savedLocations = await _savedLocationsService.getSavedLocations();
        setState(() {});
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to save location'), backgroundColor: Colors.red));
      }
    }
  }

  // Show saved locations management dialog (minimal)
  void _showSavedLocationsDialog() async {
    final locations = await _savedLocationsService.getSavedLocations();
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          'Saved Locations',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: locations.isEmpty
              ? Container(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.location_off,
                        size: 48,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No saved locations yet',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Long press on the map to save locations',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[500],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: locations.length,
                  itemBuilder: (context, index) {
                    final loc = locations[index];
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: loc.type == 'home' 
                              ? Colors.blue.withOpacity(0.2)
                              : Colors.orange.withOpacity(0.2),
                          child: Icon(
                            loc.type == 'home' ? Icons.home : Icons.work,
                            color: loc.type == 'home' ? Colors.blue : Colors.orange,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          loc.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                          ),
                        ),
                        subtitle: Text(
                          loc.address,
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          color: Colors.red[400],
                          onPressed: () async {
                            // Show confirmation dialog
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                backgroundColor: const Color.fromARGB(255, 255, 225, 190),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                title: const Text(
                                  'Delete Location',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                                content: Text(
                                  'Are you sure you want to delete "${loc.name}"?',
                                  style: const TextStyle(color: Colors.black87),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(false),
                                    style: TextButton.styleFrom(
                                      foregroundColor: Colors.grey[600],
                                    ),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () => Navigator.of(context).pop(true),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red[400],
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                    ),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            
                            if (confirm == true) {
                              await _savedLocationsService.deleteLocation(loc.id);
                              Navigator.of(context).pop();
                              savedLocations = await _savedLocationsService.getSavedLocations();
                              if (mounted) setState(() {});
                            }
                          },
                        ),
                        onTap: () {
                          // set as destination
                          Navigator.of(context).pop();
                          _setLocationAsDestination(loc);
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: const Color.fromARGB(255, 76, 175, 80),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            child: const Text(
              'Close',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  // Show selector for quick location (1=home,2=work)
  void _showLocationSelector(int n) async {
    final locations = await _savedLocationsService.getSavedLocations();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      builder: (context) => ListView.builder(
        itemCount: locations.length,
        itemBuilder: (context, index) {
          final loc = locations[index];
          return ListTile(
            title: Text(loc.name),
            subtitle: Text(loc.address),
            onTap: () {
              Navigator.of(context).pop();
              if (n == 1) selectedLocation1 = loc; else selectedLocation2 = loc;
              if (mounted) setState(() {});
            },
          );
        },
      ),
    );
  }

  void _selectTransportMode(String mode) {
    selectedTransportMode = mode;
    setState(() {});
  }

  // Method to show set as default dialog
  Future<void> _showSetAsDefaultDialog(BuildContext context, SavedLocation location, int locationNumber) async {
    final locationTypeText = locationNumber == 1 ? 'Home' : 'Work';
    
    final shouldSetDefault = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color.fromARGB(255, 255, 225, 190),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Set as Default $locationTypeText',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          content: Text(
            'Do you want to set "${location.name}" as your default $locationTypeText location?\n\n'
            'This will automatically load this location every time you open the app.',
            style: const TextStyle(color: Colors.black87),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              style: TextButton.styleFrom(
                foregroundColor: Colors.grey[600],
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              child: const Text('Just Select'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 76, 175, 80),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Set as Default',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );

    if (shouldSetDefault == true) {
      Navigator.pop(context, {'location': location, 'setAsDefault': true});
    } else if (shouldSetDefault == false) {
      Navigator.pop(context, {'location': location, 'setAsDefault': false});
    }
  }

  // Method to set a location as default
  Future<void> _setLocationAsDefault(SavedLocation location, int locationNumber) async {
    try {
      bool success = false;
      
      if (locationNumber == 1) {
        success = await _userPreferencesService.saveDefaultHomeLocation(location);
      } else {
        success = await _userPreferencesService.saveDefaultWorkLocation(location);
      }

      if (success) {
        final locationTypeText = locationNumber == 1 ? 'Home' : 'Work';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${location.name} set as default $locationTypeText location'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: 'Undo',
              textColor: Colors.white,
              onPressed: () async {
                if (locationNumber == 1) {
                  await _userPreferencesService.clearDefaultHomeLocation();
                } else {
                  await _userPreferencesService.clearDefaultWorkLocation();
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Default $locationTypeText location cleared'),
                    backgroundColor: Colors.orange,
                  ),
                );
              },
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to set default location. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      print('Error setting default location: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error setting default location.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Helper method to check if a location is set as default
  bool _isDefaultLocation(SavedLocation? location, int locationNumber) {
    if (location == null) return false;
    
    return (locationNumber == 1 && _isLocation1Default) ||
           (locationNumber == 2 && _isLocation2Default);
  }

  // Method to set a saved location as the destination for journey
  void _setLocationAsDestination(SavedLocation? location) {
    if (location == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No location selected. Please select a location first.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      // Set the destination text field
      destinationController.text = location.name;
      
      // Store the selected destination coordinates and name
      selectedDestinationCoords = location.coordinates;
      selectedDestinationName = location.name;
    });

    // Move map to the selected location
    mapController.move(location.coordinates, 15.0);

    // Show confirmation
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${location.name} set as destination'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
        action: SnackBarAction(
          label: 'Start Journey',
          textColor: Colors.white,
          onPressed: _navigateToJourney,
        ),
      ),
    );
  }



  // Method to handle map long press for saving locations
  Future<void> _onMapLongPress(LatLng point) async {
    print('📍 Map long pressed at: ${point.latitude}, ${point.longitude}');
    
    // Show immediate feedback that long press was detected
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Location detected! Getting address...'),
        duration: Duration(seconds: 2),
        backgroundColor: Colors.blue,
      ),
    );
    
    try {
      // Get address for the tapped location
      final url = 'https://nominatim.openstreetmap.org/reverse?lat=${point.latitude}&lon=${point.longitude}&format=json';
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'SafeGoEmergencyApp/1.0 (contact@safego.app)',
          'Accept': 'application/json',
          'Accept-Language': 'en-US,en;q=0.9',
          'Referer': 'https://safego.app'
        },
      );

      String address = 'Unknown address';
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        address = data['display_name'] ?? 'Unknown address';
        
        // Format the address nicely
        if (data['address'] != null) {
          address = _formatMalaysianAddress(data['address'], address);
        }
      }

      print('🏠 Retrieved address: $address');
      // Show save location dialog
      await _showLocationSaveDialog(
        coordinates: point,
        address: address,
      );
    } catch (e) {
      print('❌ Error getting address for long press: $e');
      // Still show dialog with coordinates
      await _showLocationSaveDialog(
        coordinates: point,
        address: 'Lat: ${point.latitude.toStringAsFixed(6)}, Lon: ${point.longitude.toStringAsFixed(6)}',
      );
    }
  }

  // Method to navigate to face scan page with coordinates
  void _navigateToJourney() {
    final destination = destinationController.text.trim();
    
    // Check if destination is empty
    if (destination.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a destination'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    // Check if a valid location was selected from suggestions
    if (selectedDestinationCoords == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a destination from the suggestions'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    // Navigate to FaceScan page
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FaceScan(
          destination: destination,
          currentLocation: currentLocation,
          currentAddress: currentAddress,
          destinationCoords: selectedDestinationCoords, // Pass selected coordinates 
          transportMode: selectedTransportMode, // Pass selected transport mode
        ),
      ),
    );
  }

  // Method to search for locations using Nominatim API
  Future<void> _searchLocations(String query) async {
    if (query.isEmpty) {
      setState(() {
        locationSuggestions = [];
      });
      _hideOverlay();
      return;
    }

    setState(() {
      isSearching = true;
    });

    try {
      // Enhanced query for Malaysian locations
      String searchQuery = query;
      
      // If query doesn't contain "Malaysia", add it to prioritize Malaysian location results
      if (!query.toLowerCase().contains('malaysia') && 
          !query.toLowerCase().contains('kuala lumpur') && 
          !query.toLowerCase().contains('selangor') && 
          !query.toLowerCase().contains('johor') && 
          !query.toLowerCase().contains('penang')) {
        searchQuery = '$query, Malaysia';
      }
      
      // Encode the query for URL
      final encodedQuery = Uri.encodeComponent(searchQuery);
      
      // Build URL with proximity bias
      String url = 'https://nominatim.openstreetmap.org/search?'
          'q=$encodedQuery'
          '&format=json'
          '&limit=12'
          '&addressdetails=1'
          '&countrycodes=MY'
          '&dedupe=1';
      
      // Add proximity bias if we have current location
      if (currentLocation != null) {
        // Create a smaller search radius around current location (approximately 50km)
        final lat = currentLocation!.latitude;
        final lon = currentLocation!.longitude;
        final radius = 0.45; // Approximately 50km radius
        
        url += '&viewbox=${lon - radius},${lat + radius},${lon + radius},${lat - radius}'
            '&bounded=1'
            '&proximity=$lat,$lon';
      } else {
        // Fallback to Malaysian bounding box if no current location
        // West: 99.6, South: 0.8, East: 119.3, North: 7.4
        url += '&viewbox=99.6,7.4,119.3,0.8&bounded=1';
      }
      
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'SafeGoEmergencyApp/1.0 (contact@safego.app)',
          'Accept': 'application/json',
          'Accept-Language': 'en-US,en;q=0.9',
          'Referer': 'https://safego.app'
        },
      );

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          List<Map<String, dynamic>> processedLocations = data.where((location) => location != null).map((location) {
            try {
              final address = location['address'];
              final rawDisplayName = location['display_name']?.toString() ?? 'Unknown location';
              
              // Build a more readable address for Malaysian locations
              String displayName = _formatMalaysianAddress(address, rawDisplayName);
              
              // Ensure we have valid coordinates
              final lat = double.tryParse(location['lat']?.toString() ?? '0') ?? 0.0;
              final lon = double.tryParse(location['lon']?.toString() ?? '0') ?? 0.0;
              
              // Skip locations with invalid coordinates
              if (lat == 0.0 && lon == 0.0) {
                return null;
              }
              
              // Calculate distance from current location if available
              double? distanceKm;
              if (currentLocation != null) {
                distanceKm = _calculateDistance(
                  currentLocation!.latitude, 
                  currentLocation!.longitude, 
                  lat, 
                  lon
                );
              }
              
              return {
                'display_name': displayName,
                'lat': lat,
                'lon': lon,
                'type': location['type']?.toString() ?? 'location',
                'raw_address': address ?? {},
                'distance_km': distanceKm,
              };
            } catch (e) {
              print('Error processing location: $e');
              return null;
            }
          }).where((location) => location != null).cast<Map<String, dynamic>>().toList();
          
          // Sort by distance if current location is available
          if (currentLocation != null) {
            processedLocations.sort((a, b) {
              final distanceA = a['distance_km'] as double? ?? double.maxFinite;
              final distanceB = b['distance_km'] as double? ?? double.maxFinite;
              return distanceA.compareTo(distanceB);
            });
          }
          
          // Take only the closest 8 results for better UI
          locationSuggestions = processedLocations.take(8).toList();
        });
        
        if (locationSuggestions.isNotEmpty) {
          _showOverlay();
        }
      } else {
        setState(() {
          locationSuggestions = [];
        });
      }
    } catch (e) {
      print('Location search error: $e');
      setState(() {
        locationSuggestions = [];
      });
    } finally {
      setState(() {
        isSearching = false;
      });
    }
  }

  // Helper method to format Malaysian addresses more clearly
  String _formatMalaysianAddress(Map<String, dynamic>? address, String fallback) {
    if (address == null || address.isEmpty) {
      return _cleanDisplayName(fallback);
    }

    List<String> parts = [];
    
    try {
      // Helper function to safely add non-null, non-empty values
      void addIfValid(String? value) {
        if (value != null && value.isNotEmpty && value.trim().isNotEmpty) {
          parts.add(value.trim());
        }
      }
      
      // Add specific place name (shop, building, etc.)
      addIfValid(address['shop']?.toString());
      addIfValid(address['amenity']?.toString());
      addIfValid(address['building']?.toString());
      addIfValid(address['tourism']?.toString());
      
      // Add road/street
      addIfValid(address['road']?.toString());
      if (parts.isEmpty || !parts.any((p) => p.toLowerCase().contains('jalan') || p.toLowerCase().contains('road'))) {
        addIfValid(address['pedestrian']?.toString());
      }
      
      // Add area/suburb
      addIfValid(address['suburb']?.toString());
      if (parts.length < 3) {
        addIfValid(address['neighbourhood']?.toString());
        addIfValid(address['quarter']?.toString());
      }
      
      // Add city/town
      addIfValid(address['city']?.toString());
      if (parts.length < 4) {
        addIfValid(address['town']?.toString());
      }
      
      // Add state
      addIfValid(address['state']?.toString());
      
      // Add postcode if available and we don't have too many parts
      if (parts.length < 5) {
        addIfValid(address['postcode']?.toString());
      }
      
      // If we have enough parts, format nicely, otherwise use fallback
      if (parts.length >= 2 && parts.length <= 6) {
        // Limit to maximum 4 parts for readability
        List<String> limitedParts = parts.take(4).toList();
        return limitedParts.join(', ');
      } else if (parts.length == 1) {
        return parts[0];
      } else {
        return _cleanDisplayName(fallback);
      }
    } catch (e) {
      // If any error occurs in formatting, fall back to cleaned display name
      print('Error formatting address: $e');
      return _cleanDisplayName(fallback);
    }
  }

  // Helper method to clean up display names
  String _cleanDisplayName(String displayName) {
    try {
      if (displayName.isEmpty) return 'Unknown location';
      
      // Clean up the fallback display name
      String cleaned = displayName.replaceAll(RegExp(r'\d+,\s*'), '');
      cleaned = cleaned.trim();
      
      // Limit length to prevent UI overflow
      if (cleaned.length > 80) {
        cleaned = '${cleaned.substring(0, 80)}...';
      }
      
      return cleaned.isEmpty ? 'Unknown location' : cleaned;
    } catch (e) {
      print('Error cleaning display name: $e');
      return 'Unknown location';
    }
  }

  // Helper method to calculate distance between two points using Haversine formula
  double _calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    try {
      const double earthRadius = 6371.0; // Earth's radius in kilometers
      
      // Convert degrees to radians
      double lat1Rad = lat1 * math.pi / 180;
      double lat2Rad = lat2 * math.pi / 180;
      double deltaLatRad = (lat2 - lat1) * math.pi / 180;
      double deltaLonRad = (lon2 - lon1) * math.pi / 180;
      
      // Haversine formula
      double a = math.sin(deltaLatRad / 2) * math.sin(deltaLatRad / 2) +
          math.cos(lat1Rad) * math.cos(lat2Rad) *
          math.sin(deltaLonRad / 2) * math.sin(deltaLonRad / 2);
      double c = 2 * math.asin(math.sqrt(a));
      
      return earthRadius * c;
    } catch (e) {
      print('Error calculating distance: $e');
      return double.maxFinite;
    }
  }

  // Helper method to build subtitle with distance and type information
  Widget? _buildSubtitle(Map<String, dynamic> suggestion, String locationType, Color iconColor) {
    List<String> subtitleParts = [];
    
    // Add location type if not generic
    if (locationType != 'location') {
      subtitleParts.add(locationType.toUpperCase());
    }
    
    // Add distance if available
    final distance = suggestion['distance_km'] as double?;
    if (distance != null && distance < double.maxFinite) {
      String distanceText;
      if (distance < 1) {
        distanceText = '${(distance * 1000).round()}m away';
      } else {
        distanceText = '${distance.toStringAsFixed(1)}km away';
      }
      subtitleParts.add(distanceText);
    }
    
    if (subtitleParts.isEmpty) return null;
    
    return Text(
      subtitleParts.join(' • '),
      style: TextStyle(
        fontSize: 11,
        color: iconColor.withOpacity(0.8),
        fontWeight: FontWeight.w500,
      ),
    );
  }

  // Method to show location suggestions overlay
  void _showOverlay() {
    if (_overlayEntry != null || locationSuggestions.isEmpty) return;

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: MediaQuery.of(context).size.width - 32,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 60),
          child: Material(
            elevation: 4.0,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: locationSuggestions.length,
                itemBuilder: (context, index) {
                  if (index >= locationSuggestions.length) {
                    return const SizedBox.shrink();
                  }
                  
                  final suggestion = locationSuggestions[index];
                  final locationType = suggestion['type']?.toString() ?? 'location';
                  
                  // Choose appropriate icon based on location type
                  IconData icon = Icons.location_on;
                  Color iconColor = Colors.red;
                  
                  switch (locationType) {
                    case 'amenity':
                      icon = Icons.place;
                      iconColor = Colors.blue;
                      break;
                    case 'shop':
                      icon = Icons.store;
                      iconColor = Colors.green;
                      break;
                    case 'tourism':
                      icon = Icons.camera_alt;
                      iconColor = Colors.orange;
                      break;
                    case 'highway':
                    case 'road':
                      icon = Icons.directions;
                      iconColor = Colors.grey[600]!;
                      break;
                    default:
                      icon = Icons.location_on;
                      iconColor = Colors.red;
                  }
                  
                  return Container(
                    decoration: BoxDecoration(
                      border: index < locationSuggestions.length - 1
                          ? Border(bottom: BorderSide(color: Colors.grey[200]!, width: 0.5))
                          : null,
                    ),
                    child: ListTile(
                      leading: Icon(icon, color: iconColor, size: 20),
                      title: Text(
                        suggestion['display_name']?.toString() ?? 'Unknown location',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: _buildSubtitle(suggestion, locationType, iconColor),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      onTap: () => _selectLocation(suggestion),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  // Method to hide location suggestions overlay
  void _hideOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  // Method to handle location selection from suggestions
  void _selectLocation(Map<String, dynamic> location) {
    final displayName = location['display_name']?.toString() ?? 'Unknown location';
    final lat = location['lat'] as double? ?? 0.0;
    final lon = location['lon'] as double? ?? 0.0;
    
    // Store the selected location data
    selectedDestinationCoords = LatLng(lat, lon);
    selectedDestinationName = displayName;
    
    destinationController.text = displayName;
    _hideOverlay();
    _focusNode.unfocus();
    
    // Move map to selected location
    if (lat != 0.0 && lon != 0.0) {
      mapController.move(LatLng(lat, lon), 15.0);
    }
  }

  // Method to handle text input changes with debouncing
  void _onSearchChanged(String query) {
    // Clear stored coordinates when user types manually
    if (selectedDestinationName != null && query != selectedDestinationName) {
      selectedDestinationCoords = null;
      selectedDestinationName = null;
    }
    
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _searchLocations(query);
    });
  }

  // Method to convert coordinates to address (from ConvertLatLong)
  Future<void> getAddress(double lat, double lon) async {
    if (!mounted) return;
    
    // Validate coordinates
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      debugPrint('Invalid coordinates: lat=$lat, lon=$lon');
      setState(() {
        currentAddress = 'Invalid location coordinates';
      });
      return;
    }
    
    try {
      final url = 'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json';

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'SafeGoEmergencyApp/1.0 (contact@safego.app)',
          'Accept': 'application/json',
          'Accept-Language': 'en-US,en;q=0.9',
          'Referer': 'https://safego.app'
        },
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Address lookup timed out', const Duration(seconds: 10));
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final address = data['display_name']?.toString();
        
        if (address != null && address.isNotEmpty) {
          setState(() {
            currentAddress = address;
          });
        } else {
          setState(() {
            currentAddress = 'Address not available';
          });
        }
      } else {
        print('Address lookup failed with status: ${response.statusCode}');
        if (mounted) {
          setState(() {
            currentAddress = 'Location services unavailable';
          });
        }
      }
    } catch (e) {
      print('Address lookup error: $e');
      if (mounted) {
        setState(() {
          currentAddress = 'Unable to get address';
        });
      }
    }
  }

  // Method to get current location
  Future<void> _getCurrentLocation() async {
    if (!mounted) return;
    setState(() {
      isLoading = true;
    });

    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }
        return;
      }

      // Check location permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            setState(() {
              isLoading = false;
            });
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }
        return;
      }

      // Get current location with timeout
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );

      if (!mounted) return;
      
      final newLocation = LatLng(position.latitude, position.longitude);
      
      setState(() {
        currentLocation = newLocation;
        isLoading = false;
      });

      // Center map on current location
      mapController.move(newLocation, 15.0);
      
      // Get address for the location (async, doesn't block UI)
      getAddress(newLocation.latitude, newLocation.longitude);
      
    } catch (e) {
      print('Location error: $e');
      if (mounted) {
        setState(() {
          isLoading = false;
          // Provide user-friendly error messages
          if (e.toString().contains('timeout') || e.toString().contains('TIMEOUT')) {
            currentAddress = 'Location timeout - please try again';
          } else if (e.toString().contains('permission') || e.toString().contains('PERMISSION')) {
            currentAddress = 'Location permission required';
          } else {
            currentAddress = 'Unable to get current location';
          }
        });
      }
    }
  }

  // Helper method to build transport mode buttons
  Widget _buildTransportButton({
    required IconData icon,
    required String label,
    required String mode,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 100, 
            height: 48,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSelected 
                ? const Color.fromARGB(255, 76, 175, 80) 
                : const Color.fromARGB(255, 255, 241, 217), 
              borderRadius: BorderRadius.circular(12),
              border: isSelected 
                ? Border.all(color: const Color.fromARGB(255, 56, 142, 60), width: 2)
                : null,
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8,
                  offset: Offset(0, 4), 
                ),
              ],
            ),
            child: Icon(
              icon,
              color: isSelected ? Colors.white : Colors.black,
              size: 25,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 100, 
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isSelected 
                  ? const Color.fromARGB(255, 56, 142, 60) 
                  : const Color.fromARGB(255, 143, 142, 142),
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.green,
      appBar: AppBar(
        backgroundColor: const Color.fromARGB(255, 255, 225, 190), 
        foregroundColor: Colors.black, 
        centerTitle: true,
        title: FutureBuilder<User?>(
          future: Future.value(FirebaseAuth.instance.currentUser),
          builder: (context, snapshot) {
            final user = snapshot.data;
            final displayName = user?.displayName ?? user?.email ?? 'User';
            return Text(
              'Welcome, $displayName!',
              style: const TextStyle(fontWeight: FontWeight.normal),
            );
          },
        ),
        elevation: 4,
        shadowColor: Colors.black54,
        leading: IconButton(
          icon: const Icon(Icons.logout),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => SignIn()),
            );
          }
        ),
      ),

 ///////////////Start BottomNavigationBar//////////////////
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, -1), 
            ),
          ],
        ),
        child: BottomNavigationBar(
          backgroundColor: const Color.fromARGB(255, 255, 225, 190),
          selectedItemColor: Colors.black, 
          unselectedItemColor: Colors.grey,
          currentIndex: 0, 
          onTap: (index) {
            if (index == 0) {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const HomePage()),
              );
            } else if (index == 1) {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const MyProfile()),
              );
            }
          },
          items: [
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
      
///////////// Floating SOS Button positioned closer to BottomNavigationBar ///////////
      floatingActionButton: SizedBox(
        width: 80, 
        height: 80, 
        child: FloatingActionButton(
          onPressed: () {
            EmergencyAlert.show(context);
          },
          backgroundColor: Colors.white,
          heroTag: "sosButton", 
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
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,

 ///////////////End BottomNavigationBar////////////////////////



///////////Main Body Layer that divides the top and bottom tabs////////////
      body: Stack(
        children: <Widget>[
          // Main content (live map) will show on full screen
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: currentLocation ?? LatLng(3.1390, 101.6869), // Default to Kuala Lumpur
              initialZoom: 15.0,
              onLongPress: (tapPosition, point) => _onMapLongPress(point),
            ),
            children: [
              // Tile layer (map background)
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.flutterbiometrics',
              ),

              // Current location marker
              if (currentLocation != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: currentLocation!,
                      radius: 10,
                      color: Colors.blue.withOpacity(0.7),
                      borderColor: Colors.white,
                      borderStrokeWidth: 2,
                    ),
                  ],
                ),

              // Saved locations markers
              if (savedLocations.isNotEmpty)
                MarkerLayer(
                  markers: savedLocations.map((location) {
                    Color markerColor = Colors.red;
                    IconData markerIcon = Icons.place;
                    
                    switch (location.type) {
                      case 'home':
                        markerColor = Colors.blue;
                        markerIcon = Icons.location_on;
                        break;
                      case 'office':
                        markerColor = Colors.orange;
                        markerIcon = Icons.location_on;
                        break;
                      default:
                        markerColor = Colors.red;
                        markerIcon = Icons.location_on;
                    }

                    return Marker(
                      point: location.coordinates,
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: () {
                          // Show location info
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('${location.name}: ${location.address}'),
                              duration: const Duration(seconds: 3),
                            ),
                          );
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: markerColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Icon(
                            markerIcon,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),

              // Attribution widget for OpenStreetMap
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(
                    'OpenStreetMap contributors',
                    onTap: () => launchUrl(Uri.parse('https://openstreetmap.org/copyright')),
                  ),
                ],
                alignment: AttributionAlignment.bottomLeft,
              ),
            ],
          ),

          /////// Top sheet-like panel below the app bar, that shows the current location///////
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(minHeight: 100),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(10.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 6),
                    const Text(
                      "Your current location",
                      style: TextStyle(color: Colors.grey, fontWeight: FontWeight.normal, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(Icons.location_on, color: Colors.red, size: 18),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: AutoSizeText(
                            currentAddress,
                            style: TextStyle(fontSize: 15, color: Colors.black, fontWeight: FontWeight.bold),
                            maxLines: 2,
                            minFontSize: 10,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Loading indicator
          if (isLoading)
            Container(
              color: Colors.black.withOpacity(0.3),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),

          // Refresh location button (positioned in top-right)
          Positioned(
            top: 121, // Below the top panel
            right: 16,
            child: FloatingActionButton(
              mini: true,
              onPressed: _getCurrentLocation,
              backgroundColor: Colors.white,
              heroTag: "homepageLocationRefreshButton", // Unique hero tag
              child: const Icon(Icons.my_location, color: Colors.blue),
            ),
          ),


          /////// Draggable bottom sheet-like panel above the bottom navigation bar, that shows the input locations///////
          DraggableScrollableSheet(
            initialChildSize: 0.4, // Initial height (40% of screen)
            minChildSize: 0.25, // Minimum height when collapsed (25% of screen to show transport options)
            maxChildSize: 0.85, // Maximum height when expanded (85% of screen)
            snap: true, // Snap to predefined positions
            snapSizes: const [0.25, 0.4, 0.85], // Snap positions: collapsed (with transport), default, expanded
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: const Color.fromARGB(255, 255, 225, 190),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(20),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: ListView(
                  controller: scrollController,
                  children: [
                    // Handle bar at the top of the bottom sheet (iPhone style)
                    Center(
                      child: Container(
                        width: 36,
                        height: 5,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2.5),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // "Where to?" input field with location icon
                          Row(
                            children: [
                              Expanded(
                                child: CompositedTransformTarget(
                                  link: _layerLink,
                                  child: TextField(
                                    controller: destinationController,
                                    focusNode: _focusNode,
                                    decoration: InputDecoration(
                                      hintText: "Where do you wanna go?",
                                      helperText: "You must select from suggestions to proceed",
                                      helperStyle: TextStyle(color: Colors.grey[600], fontSize: 11),
                                      prefixIcon: Icon(Icons.location_on, color: Colors.red),
                                      suffixIcon: isSearching 
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: Padding(
                                              padding: EdgeInsets.all(12),
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            ),
                                          )
                                        : Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (selectedDestinationCoords != null)
                                                Icon(Icons.check_circle, color: Colors.green, size: 20),
                                              IconButton(
                                                onPressed: () => _navigateToJourney(),
                                                icon: Icon(
                                                  Icons.search, 
                                                  color: selectedDestinationCoords != null ? Colors.green : Colors.grey, 
                                                  size: 24
                                                ),
                                                tooltip: selectedDestinationCoords != null ? 'Start Journey' : 'Select from suggestions first',
                                              ),
                                            ],
                                          ),
                                      filled: true,
                                      fillColor: const Color.fromARGB(255, 245, 245, 245),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: selectedDestinationCoords != null 
                                          ? BorderSide(color: Colors.green, width: 2)
                                          : BorderSide.none,
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: selectedDestinationCoords != null 
                                          ? BorderSide(color: Colors.green, width: 2)
                                          : BorderSide.none,
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: selectedDestinationCoords != null 
                                          ? BorderSide(color: Colors.green, width: 2)
                                          : BorderSide(color: Colors.blue, width: 2),
                                      ),
                                      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                                    ),
                                    onChanged: _onSearchChanged,
                                    onSubmitted: (value) => _navigateToJourney(),
                                    textInputAction: TextInputAction.search,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          // Header with manage button
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("Quick Locations", style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
                                ],
                              ),
                              GestureDetector(
                                onTap: _showSavedLocationsDialog,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.settings, size: 16, color: Colors.grey[600]),
                                    const SizedBox(width: 4),
                                    Text("Manage", style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Home and Work locations
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: location1Controller,
                                  readOnly: true,
                                  onTap: () {
                                    // If a location is selected, set it as destination and navigate to journey
                                    if (selectedLocation1 != null) {
                                      setState(() {
                                        destinationController.text = selectedLocation1!.name;
                                        selectedDestinationCoords = selectedLocation1!.coordinates;
                                        selectedDestinationName = selectedLocation1!.name;
                                      });
                                      
                                      // Move map to the selected location
                                      mapController.move(selectedLocation1!.coordinates, 15.0);
                                      
                                      // Show confirmation and navigate to journey
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('${selectedLocation1!.name} set as destination. Starting journey...'),
                                          backgroundColor: Colors.green,
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                      
                                      // Navigate to journey immediately
                                      Future.delayed(Duration(milliseconds: 500), () {
                                        _navigateToJourney();
                                      });
                                    } else {
                                      // If no location is set, show the location selector
                                      _showLocationSelector(1);
                                    }
                                  },
                                  decoration: InputDecoration(
                                    labelText: "Home",
                                    labelStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                                    prefixIcon: Icon(Icons.location_on, color: Colors.black),
                                    suffixIcon: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isDefaultLocation(selectedLocation1, 1))
                                          Tooltip(
                                            message: "This is your default Home location",
                                            child: Icon(Icons.star, color: Colors.amber, size: 20),
                                          ),
                                        Tooltip(
                                          message: selectedLocation1 != null 
                                              ? 'Save ${selectedLocation1!.name} as destination (without navigating)'
                                              : 'Select a home location first',
                                          child: GestureDetector(
                                            onTap: () => _setLocationAsDestination(selectedLocation1),
                                            child: Container(
                                              padding: EdgeInsets.all(8),
                                              decoration: selectedLocation1 != null 
                                                  ? BoxDecoration(
                                                      borderRadius: BorderRadius.circular(4),
                                                      color: Colors.green.withOpacity(0.1),
                                                    )
                                                  : null,
                                              child: Icon(
                                                selectedLocation1 != null 
                                                    ? Icons.arrow_forward_ios 
                                                    : Icons.keyboard_arrow_right_rounded,
                                                color: selectedLocation1 != null ? Colors.green : Colors.grey,
                                                size: selectedLocation1 != null ? 18 : 16,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    filled: true,
                                    fillColor: Colors.transparent,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: _isDefaultLocation(selectedLocation1, 1) ? Colors.blue.shade200 : Colors.grey.shade300,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: _isDefaultLocation(selectedLocation1, 1) ? Colors.blue.shade200 : Colors.grey.shade300,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: _isDefaultLocation(selectedLocation1, 1) ? Colors.blue.shade400 : Colors.grey.shade400,
                                      ),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: location2Controller,
                                  readOnly: true,
                                  onTap: () {
                                    // If a location is selected, set it as destination and navigate to journey
                                    if (selectedLocation2 != null) {
                                      setState(() {
                                        destinationController.text = selectedLocation2!.name;
                                        selectedDestinationCoords = selectedLocation2!.coordinates;
                                        selectedDestinationName = selectedLocation2!.name;
                                      });
                                      
                                      // Move map to the selected location
                                      mapController.move(selectedLocation2!.coordinates, 15.0);
                                      
                                      // Show confirmation and navigate to journey
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('${selectedLocation2!.name} set as destination. Starting journey...'),
                                          backgroundColor: Colors.green,
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                      
                                      // Navigate to journey immediately
                                      Future.delayed(Duration(milliseconds: 500), () {
                                        _navigateToJourney();
                                      });
                                    } else {
                                      // If no location is set, show the location selector
                                      _showLocationSelector(2);
                                    }
                                  },
                                  decoration: InputDecoration(
                                    labelText: "Work",
                                    labelStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                                    prefixIcon: Icon(Icons.location_on, color: Colors.black),
                                    suffixIcon: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isDefaultLocation(selectedLocation2, 2))
                                          Tooltip(
                                            message: "This is your default Work location",
                                            child: Icon(Icons.star, color: Colors.amber, size: 20),
                                          ),
                                        Tooltip(
                                          message: selectedLocation2 != null 
                                              ? 'Save ${selectedLocation2!.name} as destination (without navigating)'
                                              : 'Select a work location first',
                                          child: GestureDetector(
                                            onTap: () => _setLocationAsDestination(selectedLocation2),
                                            child: Container(
                                              padding: EdgeInsets.all(8),
                                              decoration: selectedLocation2 != null 
                                                  ? BoxDecoration(
                                                      borderRadius: BorderRadius.circular(4),
                                                      color: Colors.orange.withOpacity(0.1),
                                                    )
                                                  : null,
                                              child: Icon(
                                                selectedLocation2 != null 
                                                    ? Icons.arrow_forward_ios 
                                                    : Icons.keyboard_arrow_right_rounded,
                                                color: selectedLocation2 != null ? Colors.orange : Colors.grey,
                                                size: selectedLocation2 != null ? 18 : 16,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    filled: true,
                                    fillColor: Colors.transparent,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: _isDefaultLocation(selectedLocation2, 2) ? Colors.orange.shade200 : Colors.grey.shade300,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: _isDefaultLocation(selectedLocation2, 2) ? Colors.orange.shade200 : Colors.grey.shade300,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: BorderSide(
                                        color: _isDefaultLocation(selectedLocation2, 2) ? Colors.orange.shade400 : Colors.grey.shade400,
                                      ),
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          // Mode of transport buttons
                          Row(
                            children: [
                              const Text("Mode Of Transport", style: TextStyle(fontWeight: FontWeight.normal)),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildTransportButton(
                                icon: Icons.directions_car,
                                label: "Drive",
                                mode: "driving",
                                isSelected: selectedTransportMode == "driving",
                                onTap: () => _selectTransportMode("driving"),
                              ),
                              _buildTransportButton(
                                icon: Icons.directions_transit,
                                label: "Transit",
                                mode: "transit",
                                isSelected: selectedTransportMode == "transit",
                                onTap: () => _selectTransportMode("transit"),
                              ),
                              _buildTransportButton(
                                icon: Icons.directions_walk,
                                label: "Walk",
                                mode: "walking",
                                isSelected: selectedTransportMode == "walking",
                                onTap: () => _selectTransportMode("walking"),
                              ),
                            ],
                          ),
                          const SizedBox(height: 25),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),


          ],
        ),
      );

  }

  @override
  void dispose() {
    destinationController.dispose();
    location1Controller.dispose();
    location2Controller.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    _hideOverlay();
    super.dispose();
  }
}
