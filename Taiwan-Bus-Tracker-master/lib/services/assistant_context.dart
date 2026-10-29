// Live context handed to the AI assistant: where the user is, the closest
// stops and what is arriving there. Without this Claude could only give
// generic advice; with it, it can answer "when is my bus?" from real data.

import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/bus_models.dart';
import '../utils/theme.dart';
import 'ptx_api.dart';

class AssistantContext {
  AssistantContext._();

  static String? _cached;
  static DateTime? _cachedAt;

  /// The user's position, or null without location permission.
  static Future<LatLng?> position() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm != LocationPermission.always &&
          perm != LocationPermission.whileInUse) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.medium),
      ).timeout(const Duration(seconds: 8));
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// Plain-text summary for the system prompt; '' when nothing is available.
  /// Cached for a minute so a back-and-forth chat doesn't hammer PTX.
  static Future<String> load() async {
    if (_cached != null &&
        DateTime.now().difference(_cachedAt!) < const Duration(minutes: 1)) {
      return _cached!;
    }
    final lines = <String>[
      'Current local time: ${DateTime.now().toString().substring(0, 16)}',
      'City: $defaultCity',
    ];
    try {
      final pos = await position();
      if (pos != null) {
        lines.add('User location: ${pos.latitude.toStringAsFixed(5)}, '
            '${pos.longitude.toStringAsFixed(5)}');

        final stops = await PtxApi.instance
            .getNearbyStops(pos.latitude, pos.longitude, defaultCity);
        double dist(BusStop s) => haversineDistance(pos.latitude,
            pos.longitude, s.stopPosition.lat, s.stopPosition.lon);
        stops.sort((a, b) => dist(a).compareTo(dist(b)));

        // Same physical stop appears once per direction — keep unique names.
        final seen = <String>{};
        final nearest = stops.where((s) => seen.add(s.stopName.zhTw)).take(3);
        for (final s in nearest) {
          final name = s.stopName.en.isNotEmpty
              ? '${s.stopName.zhTw} (${s.stopName.en})'
              : s.stopName.zhTw;
          lines.add('Nearby stop: $name, ${dist(s).round()} m away');
          final arrivals =
              await PtxApi.instance.getStopArrivals(s.stopUID, defaultCity);
          for (final a in arrivals.where((a) => a.estimateTime >= 0).take(5)) {
            final mins = (a.estimateTime / 60).round();
            lines.add('  - route ${a.routeName.zhTw}: '
                '${mins == 0 ? 'arriving now' : 'in $mins min'}');
          }
        }
      } else {
        lines.add('User location: unknown (permission not granted)');
      }
    } catch (_) {
      lines.add('Live bus data: unavailable right now');
    }
    _cached = lines.join('\n');
    _cachedAt = DateTime.now();
    return _cached!;
  }
}
