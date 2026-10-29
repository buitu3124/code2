// Step-by-step bus directions for the sign-language assistant:
// walk to stop X → take bus N → ride K stops → get off at Y → walk.
//
// Uses the same Google Directions (transit) API as the map. Google geocodes a
// place *name* as the destination itself, which finds shops Nominatim misses
// (e.g. "nova taichung store"); Nominatim / the curated list are the
// fallback. The first bus gets a live arrival time from TDX when possible.

import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../models/bus_models.dart';
import '../utils/theme.dart';
import 'place_search.dart';
import 'ptx_api.dart';

enum TripStepKind { walk, bus }

class TripStep {
  final TripStepKind kind;
  final int meters; // walk
  final int minutes; // walk / ride time
  final String? line; // bus route number
  final String? headsign; // direction the bus is heading
  final String? fromStop;
  final String? toStop;
  final int numStops;

  /// Minutes until the next bus reaches [fromStop] (live TDX data), if known.
  final int? liveEtaMins;

  const TripStep.walk({required this.meters, required this.minutes, this.toStop})
      : kind = TripStepKind.walk,
        line = null,
        headsign = null,
        fromStop = null,
        numStops = 0,
        liveEtaMins = null;

  const TripStep.bus({
    required this.line,
    required this.headsign,
    required this.fromStop,
    required this.toStop,
    required this.numStops,
    required this.minutes,
    this.liveEtaMins,
  })  : kind = TripStepKind.bus,
        meters = 0;

  TripStep withLiveEta(int? mins) => kind == TripStepKind.walk
      ? this
      : TripStep.bus(
          line: line,
          headsign: headsign,
          fromStop: fromStop,
          toStop: toStop,
          numStops: numStops,
          minutes: minutes,
          liveEtaMins: mins);

  Map<String, dynamic> toJson() => kind == TripStepKind.walk
      ? {'type': 'walk', 'meters': meters, 'minutes': minutes, 'to': toStop}
      : {
          'type': 'bus',
          'route': line,
          'heading_to': headsign,
          'board_at': fromStop,
          'get_off_at': toStop,
          'stops': numStops,
          'ride_minutes': minutes,
          'next_bus_in_minutes': liveEtaMins,
        };
}

class TripPlan {
  final String destination; // name as found
  final String address;
  final double distanceKm; // straight line from the user
  final int totalMinutes;
  final List<TripStep> steps;

  const TripPlan({
    required this.destination,
    required this.address,
    required this.distanceKm,
    required this.totalMinutes,
    required this.steps,
  });

  Iterable<TripStep> get busSteps =>
      steps.where((s) => s.kind == TripStepKind.bus);

  Map<String, dynamic> toJson() => {
        'destination': destination,
        'address': address,
        'straight_line_km': double.parse(distanceKm.toStringAsFixed(1)),
        'total_minutes': totalMinutes,
        'steps': [for (final s in steps) s.toJson()],
      };
}

class TripPlanner {
  TripPlanner._();

  /// Plans a bus trip from [origin] to the first of [queries] that resolves.
  /// Pass [destination] instead when the coordinates are already known.
  /// Returns null when no route (bus or walk) could be found.
  static Future<TripPlan?> plan({
    required LatLng origin,
    List<String> queries = const [],
    PlaceResult? destination,
  }) async {
    TripPlan? plan;
    if (destination != null) {
      plan = await _directions(origin, '${destination.lat},${destination.lon}',
          name: destination.shortName);
    } else {
      // 1. Let Google resolve the name (best for shops and businesses).
      for (final q in queries) {
        // Google returns only an address, so show the name that matched.
        plan = await _directions(origin, q, name: q);
        if (plan != null) break;
      }
      // 2. Fall back to Nominatim / the curated list.
      if (plan == null) {
        for (final q in queries) {
          final places = await searchPlaces(q, origin);
          if (places.isEmpty) continue;
          final p = places.first;
          plan = await _directions(origin, '${p.lat},${p.lon}',
              name: p.shortName);
          if (plan != null) break;
        }
      }
    }
    if (plan == null) return null;

    // Live arrival for the first bus.
    final firstBus = plan.busSteps.firstOrNull;
    if (firstBus == null) return plan;
    final eta = await _liveEta(firstBus);
    return TripPlan(
      destination: plan.destination,
      address: plan.address,
      distanceKm: plan.distanceKm,
      totalMinutes: plan.totalMinutes,
      steps: [
        for (final s in plan.steps)
          identical(s, firstBus) ? s.withLiveEta(eta) : s,
      ],
    );
  }

  /// Resolves a place name to coordinates for the map (e.g. from a voice
  /// command). Google Directions geocodes names that Nominatim misses; the
  /// curated list / Nominatim is the fallback.
  static Future<PlaceResult?> findPlace(
      LatLng origin, List<String> names) async {
    for (final name in names) {
      try {
        final uri =
            Uri.parse('https://maps.googleapis.com/maps/api/directions/json')
                .replace(queryParameters: {
          'origin': '${origin.latitude},${origin.longitude}',
          'destination': name,
          'mode': 'driving',
          'language': 'zh-TW',
          'region': 'tw',
          'key': googleMapsApiKey,
        });
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) continue;
        final data =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        if (data['status'] != 'OK') continue;
        final leg = ((data['routes'] as List).first['legs'] as List).first
            as Map<String, dynamic>;
        final end = leg['end_location'] as Map<String, dynamic>;
        final lat = (end['lat'] as num).toDouble();
        final lon = (end['lng'] as num).toDouble();
        if (haversineDistance(origin.latitude, origin.longitude, lat, lon) >
            80000) {
          continue; // matched something in another city
        }
        return PlaceResult(
          shortName: name,
          displayName: leg['end_address'] as String? ?? name,
          lat: lat,
          lon: lon,
        );
      } catch (_) {
        continue;
      }
    }
    for (final name in names) {
      final places = await searchPlaces(name, origin);
      if (places.isNotEmpty) return places.first;
    }
    return null;
  }

  static Future<TripPlan?> _directions(LatLng origin, String destination,
      {String? name}) async {
    try {
      final uri = Uri.parse('https://maps.googleapis.com/maps/api/directions/json')
          .replace(queryParameters: {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': destination,
        'mode': 'transit',
        'transit_mode': 'bus',
        'alternatives': 'true',
        'language': 'zh-TW',
        'region': 'tw',
        'key': googleMapsApiKey,
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      if (data['status'] != 'OK') return null;

      final plans = <TripPlan>[];
      for (final route in data['routes'] as List) {
        final leg = (route['legs'] as List).first as Map<String, dynamic>;
        final end = leg['end_location'] as Map<String, dynamic>;
        final endLat = (end['lat'] as num).toDouble();
        final endLon = (end['lng'] as num).toDouble();
        final distKm = haversineDistance(
                origin.latitude, origin.longitude, endLat, endLon) /
            1000;
        // A name matched in another city is not what the user meant.
        if (distKm > 80) return null;

        final steps = <TripStep>[];
        for (final s in leg['steps'] as List) {
          final mins = (((s['duration'] as Map)['value'] as num) / 60).ceil();
          if (s['travel_mode'] == 'TRANSIT') {
            final td = s['transit_details'] as Map<String, dynamic>;
            final line = td['line'] as Map<String, dynamic>;
            steps.add(TripStep.bus(
              line: (line['short_name'] ?? line['name']) as String?,
              headsign: td['headsign'] as String?,
              fromStop: (td['departure_stop'] as Map)['name'] as String?,
              toStop: (td['arrival_stop'] as Map)['name'] as String?,
              numStops: (td['num_stops'] as num?)?.toInt() ?? 0,
              minutes: mins,
            ));
          } else {
            final meters = ((s['distance'] as Map)['value'] as num).toInt();
            if (meters < 30) continue;
            steps.add(TripStep.walk(meters: meters, minutes: mins));
          }
        }
        // Name each walk after where it leads: the next stop, or the end.
        final named = <TripStep>[];
        for (var i = 0; i < steps.length; i++) {
          final s = steps[i];
          if (s.kind == TripStepKind.walk) {
            final next = i + 1 < steps.length ? steps[i + 1] : null;
            named.add(TripStep.walk(
                meters: s.meters,
                minutes: s.minutes,
                toStop: next?.fromStop ?? name ?? _placeName(leg)));
          } else {
            named.add(s);
          }
        }
        plans.add(TripPlan(
          destination: name ?? _placeName(leg),
          address: leg['end_address'] as String? ?? '',
          distanceKm: distKm,
          totalMinutes: (((leg['duration'] as Map)['value'] as num) / 60).ceil(),
          steps: named,
        ));
      }
      if (plans.isEmpty) return null;

      // Easiest first: uses a bus, then fewest buses, least walking, quickest.
      int walk(TripPlan p) => p.steps.fold(0, (a, s) => a + s.meters);
      List<int> rank(TripPlan p) => [
            p.busSteps.isEmpty ? 1 : 0,
            p.busSteps.length,
            walk(p),
            p.totalMinutes,
          ];
      plans.sort((a, b) {
        final ra = rank(a), rb = rank(b);
        for (var i = 0; i < ra.length; i++) {
          if (ra[i] != rb[i]) return ra[i].compareTo(rb[i]);
        }
        return 0;
      });
      return plans.first;
    } catch (_) {
      return null;
    }
  }

  static String _placeName(Map<String, dynamic> leg) {
    final addr = leg['end_address'] as String? ?? '';
    return addr.isEmpty ? '?' : addr;
  }

  /// TDX names and Google names differ in small ways (臺/台, platform or
  /// lane suffixes such as "A月台" / "[專用道]"), so compare loosely.
  static String _norm(String s) => s
      .replaceAll('臺', '台')
      .replaceAll(RegExp(r'[\[\(（【].*?[\]\)）】]'), '')
      .replaceAll(RegExp(r'[A-Za-z]?月台$'), '')
      .replaceAll(RegExp(r'\s'), '');

  static bool _sameStop(String a, String b) {
    final x = _norm(a), y = _norm(b);
    return x.isNotEmpty && y.isNotEmpty && (x.contains(y) || y.contains(x));
  }

  static Future<int?> _liveEta(TripStep bus) async {
    final line = bus.line, from = bus.fromStop, to = bus.toStop;
    if (line == null || from == null || to == null) return null;
    try {
      // Work out the direction: the one where we board before we get off.
      final stops = await PtxApi.instance
          .getRouteStops(line, defaultCity)
          .timeout(const Duration(seconds: 8));
      int? direction;
      for (final d in {for (final s in stops) s.direction}) {
        final seq = stops.where((s) => s.direction == d).toList()
          ..sort((a, b) => a.stopSequence.compareTo(b.stopSequence));
        final i = seq.indexWhere((s) => _sameStop(s.stopName.zhTw, from));
        final j = seq.lastIndexWhere((s) => _sameStop(s.stopName.zhTw, to));
        if (i >= 0 && j > i) {
          direction = d;
          break;
        }
      }
      final arrivals = await PtxApi.instance
          .getEstimatedArrivals(line, defaultCity)
          .timeout(const Duration(seconds: 8));
      final times = arrivals
          .where((a) =>
              (direction == null || a.direction == direction) &&
              a.estimateTime >= 0 &&
              _sameStop(a.stopName.zhTw, from))
          .map((a) => a.estimateTime)
          .toList()
        ..sort();
      return times.isEmpty ? null : (times.first / 60).round();
    } catch (_) {
      return null;
    }
  }
}
