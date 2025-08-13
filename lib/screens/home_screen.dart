import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:panic_button/data/manual_coordinate.dart';
import 'package:panic_button/service/alarm_service.dart';
import 'package:panic_button/service/auth_service.dart';
import 'package:panic_button/service/data_service.dart';
import 'package:panic_button/service/log_service.dart';
import 'package:share_plus/share_plus.dart';
import '../models/device_info.dart';
import '../components/log_component.dart';
import '../components/device_info_bottom_sheet.dart';
import '../service/marker_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const LatLng _defaultCenter = LatLng(-8.6776782, 115.2611143);
  static const Duration _inactivityThreshold = Duration(minutes: 1);
  final Map<String, DeviceInfo> _devices = {};
  int _activeDevices = 0;
  DateTime _lastUpdateTime = DateTime.now();
  Map<String, List<String>> _logEntries = {};
  Map<String, BitmapDescriptor> _markerIcons = {};

  GoogleMapController? _mapController;
  Timer? _dataFetchTimer;
  BitmapDescriptor? _activeMarkerIcon;
  BitmapDescriptor? _inactiveMarkerIcon;
  BitmapDescriptor? _gatewayMarkerIcon;

  final AlarmService _alarmService = AlarmService();
  final DataService _dataService = DataService();
  final LogService _logService = LogService();
  final MarkerService _markerService = MarkerService();
  final AuthService _authService = AuthService();

  @override
  void initState() {
    super.initState();
    _initializeDevices();
    _startDataFetchTimer();
    _startPeriodicDeviceCheck();
    _loadLogEntries();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _createMarkerIcons();
  }

  void _initializeDevices() {
    ManualCoordinates.coordinates.forEach((id, location) {
      _devices[id] = DeviceInfo(
        id: id,
        location: location,
        lastActivity: DateTime.now().subtract(const Duration(seconds: 5)),
        isActive: false,
      );
    });
    _updateActiveDeviceCount();
  }

  Future<void> _createMarkerIcons() async {
    double webSize = 14;
    double mobileSize = 32;

    bool isMobile = Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;

    double regularSize = isMobile ? mobileSize : webSize;

    _activeMarkerIcon =
        await _markerService.createCustomMarkerBitmap(Colors.red, regularSize);
    _inactiveMarkerIcon = await _markerService.createCustomMarkerBitmap(
        Colors.green, regularSize);
    _gatewayMarkerIcon = await _markerService.createCustomMarkerBitmap(
        Colors.purple, regularSize);

    setState(() {
      _markerIcons = {
        'active': _activeMarkerIcon!,
        'inactive': _inactiveMarkerIcon!,
        'gateway': _gatewayMarkerIcon!,
      };
    });
  }

  void _startDataFetchTimer() {
    _dataFetchTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _fetchDataFromServer();
    });
  }

  void _startPeriodicDeviceCheck() {
    Timer.periodic(const Duration(seconds: 15), (timer) {
      final now = DateTime.now();
      bool statusChanged = false;

      _devices.forEach((id, device) {
        if (device.isActive &&
            now.difference(device.lastActivity) > _inactivityThreshold) {
          device.isActive = false;
          statusChanged = true;
          _addLogEntry(
              "Panic Button ${device.displayId} deactivated due to inactivity");
          _alarmService.stopAlarm();
        }
      });

      if (statusChanged) {
        setState(() {
          _updateActiveDeviceCount();
        });
      }
    });
  }

  Future<void> _loadLogEntries() async {
    final loadedEntries = await _logService.loadAllLogEntries();
    setState(() {
      _logEntries = loadedEntries;
    });
  }

  void _updateActiveDeviceCount() {
    setState(() {
      _activeDevices =
          _devices.values.where((device) => device.isActive).length;
    });
  }

  Future<void> _fetchDataFromServer() async {
    try {
      final data = await _dataService.fetchData();
      _updateDeviceInfo(data);
      setState(() {
        _lastUpdateTime = DateTime.now();
      });
    } catch (e) {
      print('Error fetching data: $e');
    }
  }

  void _updateDeviceInfo(dynamic data) {
    final now = DateTime.now();
    bool statusChanged = false;

    if (data is List && data.isNotEmpty) {
      for (var item in data) {
        if (item is Map<String, dynamic>) {
          final String deviceId = item['end_device_ids']['device_id'];
          if (_devices.containsKey(deviceId) &&
              !deviceId.toLowerCase().contains('gateway')) {
            final DeviceInfo device = _devices[deviceId]!;
            final DateTime receivedAt = DateTime.parse(item['received_at']);
            if (receivedAt.isAfter(device.lastActivity)) {
              device.lastActivity = receivedAt;
              if (!device.isActive) {
                device.isActive = true;
                statusChanged = true;
                _addLogEntry("Panic Button ${device.displayId} activated");
                _showDeviceActivationAlert(device);

                _alarmService.startPeriodicAlarm(const Duration(seconds: 15),
                    () => _devices.values.any((d) => d.isActive));
              }
            }
          }
        }
      }
    }

    if (statusChanged) {
      _updateActiveDeviceCount();
    }

    setState(() {
      _lastUpdateTime = now;
    });
  }

  void _addLogEntry(String entry) async {
    await _logService.addLogEntry(entry);
    await _loadLogEntries();
  }

  void _resetAllDevices() {
    bool anyDeviceWasActive = false;
    setState(() {
      _devices.forEach((id, device) {
        if (device.isActive) {
          anyDeviceWasActive = true;
          device.isActive = false;
        }
      });

      if (anyDeviceWasActive) {
        _addLogEntry("All Panic Buttons reset to inactive");
      }

      _alarmService.stopAlarm();
      _updateActiveDeviceCount();
      _lastUpdateTime = DateTime.now();
    });
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    _fitBounds();
  }

  void _fitBounds() {
    if (_devices.isEmpty || _mapController == null) {
      _mapController?.animateCamera(CameraUpdate.newLatLng(_defaultCenter));
      return;
    }

    double minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;

    for (var device in _devices.values) {
      minLat =
          minLat < device.location.latitude ? minLat : device.location.latitude;
      maxLat =
          maxLat > device.location.latitude ? maxLat : device.location.latitude;
      minLng = minLng < device.location.longitude
          ? minLng
          : device.location.longitude;
      maxLng = maxLng > device.location.longitude
          ? maxLng
          : device.location.longitude;
    }

    LatLngBounds bounds = LatLngBounds(
      northeast: LatLng(maxLat, maxLng),
      southwest: LatLng(minLat, minLng),
    );

    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 50));
  }

  void _showDeviceActivationAlert(DeviceInfo device) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('DANGER ALERT',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: Colors.red, size: 50),
              const SizedBox(height: 10),
              Text('Panic button ${device.displayId} is ACTIVE!',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(
                  'Location: ${device.location.latitude}, ${device.location.longitude}'),
            ],
          ),
          backgroundColor: Colors.yellow,
          actions: [
            TextButton(
              child: const Text('View on Map',
                  style: TextStyle(color: Colors.red)),
              onPressed: () {
                Navigator.of(context).pop();
                _mapController?.animateCamera(
                    CameraUpdate.newLatLngZoom(device.location, 18));
              },
            ),
            TextButton(
              child:
                  const Text('Dismiss', style: TextStyle(color: Colors.black)),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _showDeviceInfo(DeviceInfo device) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return DeviceInfoBottomSheet(
          device: device,
          onZoomToDevice: () {
            Navigator.pop(context);
            _mapController?.animateCamera(
                CameraUpdate.newLatLngZoom(device.location, 18));
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // ukuran asli gambar peta (misal 400x600)
    const double originalWidth = 2940;
    const double originalHeight = 1360;

    final List<Map<String, double>> markerPositions = [
      {"left": 1380, "top": 830}, // btn1
      {"left": 1490, "top": 815}, // btn2
      {"left": 1530, "top": 820}, // gtw1
      {"left": 1580, "top": 780}, // btn3
      {"left": 1620, "top": 680}, // btn4
      {"left": 1595, "top": 520}, // btn5
      {"left": 1565, "top": 390}, // btn6
      {"left": 1535, "top": 290}, // btn7
      {"left": 1435, "top": 290}, // btn8
      {"left": 1420, "top": 350}, // gtw2
      {"left": 1420, "top": 400}, // btn9
      {"left": 1390, "top": 517}, // btn10
      {"left": 1299, "top": 517}, // btn11
      {"left": 1535, "top": 612}, // btn12
      {"left": 1375, "top": 612}, // btn13
      {"left": 1275, "top": 612}, // btn14
      {"left": 1525, "top": 390}, // btn15
      {"left": 1495, "top": 460}, // btn16
    ];

    return Scaffold(
      body: Center(
        child: AspectRatio(
          aspectRatio: originalWidth / originalHeight, // Kunci rasio gambar
          child: LayoutBuilder(
            builder: (context, constraints) {
              double scaleX = constraints.maxWidth / originalWidth;
              double scaleY = constraints.maxHeight / originalHeight;

              return Stack(
                children: [
                  Positioned.fill(
                    child: Image.asset(
                      'image/sanur.png',
                      fit: BoxFit.fill, // Jangan cover/crop, isi penuh
                    ),
                  ),
                  ...markerPositions.asMap().entries.map((entry) {
                    int index = entry.key;
                    double left = entry.value["left"]! * scaleX;
                    double top = entry.value["top"]! * scaleY;

                    final device =
                        _devices.values.elementAt(index % _devices.length);

                    return Positioned(
                      left: left,
                      top: top,
                      child: GestureDetector(
                        onTap: () => _showDeviceInfo(device),
                        child: Icon(
                          Icons.change_circle,
                          color: device.isActive
                              ? Colors.red
                              : (index == 2 || index == 9)
                                  ? Colors.purple
                                  : Colors.green,
                          size: 17,
                        ),
                      ),
                    );
                  }).toList(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _shareLogFile() async {
    final logFile = await _logService.exportLogToFile();
    await Share.shareXFiles([XFile(logFile.path)],
        text: 'Check out the panic button logs.');
  }

  void _downloadLogFile() async {
    final filePath = await _logService.getLogFilePath();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Log file saved at: $filePath'),
      ),
    );
  }

  @override
  void dispose() {
    _alarmService.dispose();
    _dataFetchTimer?.cancel();
    _mapController?.dispose();
    super.dispose();
  }
}
