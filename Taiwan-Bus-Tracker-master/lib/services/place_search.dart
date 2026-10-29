// Place search shared by the map and the AI assistant: a curated list of
// popular Taichung places with aliases, backed by OpenStreetMap Nominatim.
// Moved out of map_screen.dart unchanged so both screens use the same code.

import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import '../utils/theme.dart';

// Same key used for Maps SDK in AndroidManifest.xml — must also have
// Directions API enabled in Google Cloud Console for this project.
const googleMapsApiKey = 'AIzaSyDUPCYVGg1mKjrkzbBtSsaopGXbY8SDj18';

// ─── Popular Taiwan locations (instant search fallback) ───────────────────────

class PlaceResult {
  final String shortName;    // Chinese name (or Nominatim result)
  final String shortNameEn;  // English name for popular locations
  final String displayName;
  final double lat;
  final double lon;
  // > 0 when this is a remembered trip the user has made on that many days.
  final int tripDays;

  const PlaceResult({
    required this.shortName,
    this.shortNameEn = '',
    required this.displayName,
    required this.lat,
    required this.lon,
    this.tripDays = 0,
  });

  factory PlaceResult.fromNominatim(Map<String, dynamic> json) {
    final full = json['display_name'] as String;
    final short = full.split(',').first.trim();
    return PlaceResult(
      shortName: short,
      displayName: full,
      lat: double.parse(json['lat'] as String),
      lon: double.parse(json['lon'] as String),
    );
  }
}

const popularPlaces = [
  PlaceResult(shortName: '逢甲大學', shortNameEn: 'Feng Chia University', displayName: '台中市西屯區逢甲大學', lat: 24.1800, lon: 120.6445),
  PlaceResult(shortName: '台中火車站', shortNameEn: 'Taichung Train Station', displayName: '台中市中區台中火車站', lat: 24.1369, lon: 120.6852),
  PlaceResult(shortName: '台中市政府', shortNameEn: 'Taichung City Hall', displayName: '台中市西屯區市政北二路', lat: 24.1634, lon: 120.6469),
  PlaceResult(shortName: '國立中興大學', shortNameEn: 'Nat\'l Chung Hsing University (NCHU)', displayName: '台中市南區興大路145號', lat: 24.1170, lon: 120.6752),
  PlaceResult(shortName: '台中榮總', shortNameEn: 'Taichung Veterans General Hospital', displayName: '台中市西屯區台灣大道四段1650號', lat: 24.1731, lon: 120.6362),
  PlaceResult(shortName: '朝馬轉運站', shortNameEn: 'Chaoma Bus Terminal', displayName: '台中市西屯區朝馬三路', lat: 24.1548, lon: 120.6245),
  PlaceResult(shortName: '高鐵台中站', shortNameEn: 'Taichung HSR Station', displayName: '台中市烏日區站區二路', lat: 24.0626, lon: 120.6854),
  PlaceResult(shortName: '台中機場', shortNameEn: 'Taichung Airport', displayName: '台中市清水區鎮南路', lat: 24.2641, lon: 120.6208),
  PlaceResult(shortName: '一中商圈', shortNameEn: 'First High School Shopping Area', displayName: '台中市北區育才街一帶', lat: 24.1534, lon: 120.6869),
  PlaceResult(shortName: '中友百貨', shortNameEn: 'Chung Yu Department Store', displayName: '台中市中區三民路三段', lat: 24.1456, lon: 120.6819),
  PlaceResult(shortName: '台中國家歌劇院', shortNameEn: 'National Taichung Theater', displayName: '台中市西屯區惠來路二段101號', lat: 24.1630, lon: 120.6447),
  PlaceResult(shortName: '新光三越台中中港', shortNameEn: 'Shin Kong Mitsukoshi Taichung', displayName: '台中市西屯區台灣大道三段301號', lat: 24.1634, lon: 120.6469),
  PlaceResult(shortName: '大里市區', shortNameEn: 'Dali District', displayName: '台中市大里區', lat: 24.0999, lon: 120.6784),
  PlaceResult(shortName: '豐原火車站', shortNameEn: 'Fengyuan Train Station', displayName: '台中市豐原區圓環南路', lat: 24.2519, lon: 120.7188),
  PlaceResult(shortName: '東海大學', shortNameEn: 'Tunghai University', displayName: '台中市龍井區台灣大道四段1727號', lat: 24.1792, lon: 120.5993),
];

const placeAliases = <String, String>{
  // Feng Chia University — covers romanised, phonetic Mandarin, and abbreviation
  'fengchia': '逢甲大學', 'feng chia': '逢甲大學', 'fengjia': '逢甲大學',
  'feng jia': '逢甲大學', 'fcu': '逢甲大學', 'feng chia university': '逢甲大學',

  // Taichung Train Station
  'taichung station': '台中火車站', 'train station': '台中火車站',
  'taichung railway': '台中火車站', 'taichung train': '台中火車站',
  'huo che zhan': '台中火車站',

  // City Hall
  'city hall': '台中市政府', 'taichung city hall': '台中市政府',

  // NCHU — covers full English name and common abbreviations
  'nchu': '國立中興大學', 'chung hsing': '國立中興大學',
  'national chung hsing': '國立中興大學',
  'chung hsing university': '國立中興大學',
  'zhong xing': '國立中興大學', 'zhongxing': '國立中興大學',

  // THSR
  'thsr': '高鐵台中站', 'hsr': '高鐵台中站', 'high speed': '高鐵台中站',
  'taichung hsr': '高鐵台中站', 'gaotie': '高鐵台中站',

  // Tunghai University
  'tunghai': '東海大學', 'dong hai': '東海大學',
  'tunghai university': '東海大學', 'thu': '東海大學',

  // Airport
  'airport': '台中機場', 'taichung airport': '台中機場',

  // Veterans General Hospital
  'veterans': '台中榮總', 'taichung veterans': '台中榮總', 'vghtc': '台中榮總',
};

List<PlaceResult> filterPopularPlaces(String query) {
  final q = query.toLowerCase().trim();
  if (q.isEmpty) return popularPlaces.take(5).toList();

  for (final entry in placeAliases.entries) {
    if (q.contains(entry.key) || entry.key.contains(q)) {
      final match = popularPlaces.firstWhere(
        (p) => p.shortName == entry.value,
        orElse: () => popularPlaces.first,
      );
      final others = popularPlaces
          .where((p) =>
              p.shortName.contains(q) ||
              p.displayName.contains(q) ||
              p.shortName != match.shortName)
          .take(4)
          .toList();
      return [match, ...others.where((p) => p.shortName != match.shortName)];
    }
  }

  return popularPlaces
      .where((p) =>
          p.shortName.contains(q) ||
          p.shortNameEn.toLowerCase().contains(q) ||
          p.displayName.contains(q) ||
          q.contains(p.shortName))
      .toList();
}

Future<List<PlaceResult>> searchPlaces(String query, LatLng origin) async {
  final q = query.trim();
  if (q.length < 2) return [];

  // Translate English alias to Chinese for a more accurate OSM lookup
  String searchQuery = q;
  final qLower = q.toLowerCase();
  for (final entry in placeAliases.entries) {
    if (qLower.contains(entry.key)) {
      searchQuery = entry.value;
      break;
    }
  }

  // Try progressively: Chinese name in Taiwan → original query in Taiwan → original query
  final queries = [
    if (searchQuery != q) '$searchQuery 台中',
    '$searchQuery Taiwan',
    '$q Taiwan',
    q,
  ];

  for (final sq in queries) {
    try {
      final uri =
          Uri.parse('https://nominatim.openstreetmap.org/search').replace(
        queryParameters: {
          'q': sq,
          'format': 'json',
          'limit': '6',
          'countrycodes': 'tw',       // restrict to Taiwan
          'accept-language': 'zh-TW,zh,en',
          'addressdetails': '1',
        },
      );
      final response = await http
          .get(uri, headers: {'User-Agent': 'TaiwanBusTracker/1.0'})
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) continue;
      final List<dynamic> data = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
      if (data.isNotEmpty) {
        // Prefer amenity/education results over roads or postcodes
        final sorted = List<Map<String, dynamic>>.from(
          data.map((e) => e as Map<String, dynamic>),
        )..sort((a, b) {
            const preferred = {'amenity', 'tourism', 'building', 'landuse'};
            final aScore = preferred.contains(a['class']) ? 0 : 1;
            final bScore = preferred.contains(b['class']) ? 0 : 1;
            if (aScore != bScore) return aScore.compareTo(bScore);
            // Same class tier — prefer whichever branch is closer to the user,
            // since chain results (e.g. a department store) return every
            // branch nationwide and Nominatim's default order favours the
            // most "important" one (often Taipei) over the nearest one.
            final aDist = haversineDistance(origin.latitude, origin.longitude,
                double.parse(a['lat'] as String), double.parse(a['lon'] as String));
            final bDist = haversineDistance(origin.latitude, origin.longitude,
                double.parse(b['lat'] as String), double.parse(b['lon'] as String));
            return aDist.compareTo(bDist);
          });
        // Substitute curated coordinates when result matches a known popular location,
        // because Nominatim returns polygon centroids which can be off for large areas.
        return sorted.map((e) {
          final r = PlaceResult.fromNominatim(e);
          for (final p in popularPlaces) {
            if (r.shortName.contains(p.shortName) ||
                p.shortName.contains(r.shortName)) {
              return PlaceResult(
                shortName: p.shortName,
                displayName: r.displayName,
                lat: p.lat,
                lon: p.lon,
              );
            }
          }
          return r;
        }).toList();
      }
    } catch (_) {
      continue;
    }
  }

  return filterPopularPlaces(q);
}
