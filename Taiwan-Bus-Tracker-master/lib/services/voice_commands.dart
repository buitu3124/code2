// Understands what the user said into the map's microphone: show nearby
// stops, open a route, find directions to a place, or answer a question.
//
// With AI configured, Claude classifies free speech ("我想去 NOVA 買電腦",
// "when does the 52 come?") and answers questions directly. Without it,
// keyword rules handle the common phrasings.

import 'assistant_context.dart';
import 'claude_api.dart';
import '../utils/app_strings.dart';

enum VoiceIntentKind { nearby, route, place, ask }

class VoiceIntent {
  final VoiceIntentKind kind;
  final String route; // for route
  final List<String> placeNames; // for place, best first
  final String reply; // spoken answer (ask) or confirmation

  const VoiceIntent(this.kind,
      {this.route = '', this.placeNames = const [], this.reply = ''});
}

class VoiceCommands {
  VoiceCommands._();

  static Future<VoiceIntent> interpret(String text, AppLanguage lang) async {
    if (ClaudeApi.isConfigured) {
      try {
        return await _withAi(text, lang);
      } catch (_) {
        // Network/AI trouble: fall back to the offline rules.
      }
    }
    return heuristic(text);
  }

  static const _nearbyWords = [
    'nearby', 'near me', 'buses near', 'close by', 'bus stop near',
    '附近', '周邊', '附近站牌', '附近公車', '最近的站',
  ];

  // Phrases around a destination that aren't part of its name.
  static final _placeFiller = RegExp(
    r"^(please\s+)?(i\s+(want|need|would like)\s+to\s+go\s+to|take\s+me\s+to|"
    r'how\s+(do|can)\s+i\s+get\s+to|directions\s+to|navigate\s+to|go\s+to|'
    r"where\s+is|where's|find)\s+|"
    r'^(請問)?(我)?(想要|想|要)?(去|到|前往)|^帶我去|^怎麼去|^如何去|'
    r'(怎麼走|怎麼去|在哪裡|在哪|的路線|please)[?？。.!！]*$',
    caseSensitive: false,
  );

  /// Offline rules (also the fallback when the AI call fails).
  static VoiceIntent heuristic(String text) {
    final t = text.trim();
    final lower = t.toLowerCase();
    if (_nearbyWords.any(lower.contains)) {
      return const VoiceIntent(VoiceIntentKind.nearby);
    }

    // A route only when it is clearly asked for: "route 52", "bus 52",
    // "52 號", "52路", "公車 52", or the number on its own — not any digit
    // inside a place name ("7-11", "台中一中 2 號出口").
    final route = RegExp(
            r'(?:route|bus|line|公車|號公車)\s*(\d{1,4}[A-Za-z]?)|'
            r'^(\d{1,4}[A-Za-z]?)\s*(?:號|路|號公車|路公車)?[?？。.]*$',
            caseSensitive: false)
        .firstMatch(t);
    if (route != null) {
      return VoiceIntent(VoiceIntentKind.route,
          route: (route.group(1) ?? route.group(2))!);
    }

    var place = t;
    for (var i = 0; i < 3; i++) {
      place = place.replaceAll(_placeFiller, '').trim();
    }
    place = place.replaceAll(RegExp(r'[?？。.!！,，]+$'), '').trim();
    return VoiceIntent(VoiceIntentKind.place,
        placeNames: {if (place.isNotEmpty) place, t}.toList());
  }

  static Future<VoiceIntent> _withAi(String text, AppLanguage lang) async {
    final language =
        lang == AppLanguage.zh ? 'Traditional Chinese (繁體中文)' : 'English';
    final live = await AssistantContext.load();
    final json = await ClaudeApi.structuredWithTools(
      system: '''
You interpret what a passenger said into the microphone of a Taichung bus app (speech-to-text, so expect recognition mistakes) and decide what the app should do:
- "nearby": they want bus stops or buses near them.
- "route": they name a bus route number and want its details. Put the number in route.
- "place": they want to go somewhere or find a place. Put names to search in place_names, best first: their wording without filler, plus the official English and Traditional Chinese names if you know them.
- "ask": anything else (a question about buses, fares, the app, the city, …). Answer it in reply.
reply is spoken aloud by text-to-speech: in $language, one to three short sentences, no lists, symbols or markdown. For nearby/route/place give a short confirmation such as "正在查詢往 NOVA 的路線". Only state bus times or stops that appear in the live data; never invent them.''',
      messages: [
        {
          'role': 'user',
          'content': 'Live data:\n$live\n\nThe passenger said: "$text"',
        },
      ],
      schema: const {
        'type': 'object',
        'properties': {
          'intent': {
            'type': 'string',
            'enum': ['nearby', 'route', 'place', 'ask'],
          },
          'route': {'type': 'string'},
          'place_names': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'reply': {'type': 'string'},
        },
        'required': ['intent', 'route', 'place_names', 'reply'],
        'additionalProperties': false,
      },
    );
    final kind = VoiceIntentKind.values.firstWhere(
        (k) => k.name == json['intent'],
        orElse: () => VoiceIntentKind.ask);
    return VoiceIntent(
      kind,
      route: json['route'] as String? ?? '',
      placeNames: [
        for (final n in (json['place_names'] as List? ?? const []))
          if (n is String && n.trim().isNotEmpty) n.trim(),
      ],
      reply: json['reply'] as String? ?? '',
    );
  }
}
