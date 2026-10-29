import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:taiwan_bus_tracker/services/claude_api.dart';
import 'package:taiwan_bus_tracker/services/voice_commands.dart';
import 'package:taiwan_bus_tracker/services/voice_service.dart';
import 'package:taiwan_bus_tracker/widgets/sign_hand/sign_vocabulary.dart';
import 'package:taiwan_bus_tracker/widgets/sign_hand/sign_hand_view.dart';

String _sse(List<Map<String, dynamic>> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

void main() {
  group('offline voice commands', () {
    VoiceIntent h(String t) => VoiceCommands.heuristic(t);

    test('nearby', () {
      expect(h('附近的公車').kind, VoiceIntentKind.nearby);
      expect(h('buses near me').kind, VoiceIntentKind.nearby);
    });

    test('route only when clearly asked for', () {
      expect(h('bus 52').route, '52');
      expect(h('52 號公車').route, '52');
      expect(h('300').route, '300');
      expect(h('台中一中 2 號出口').kind, VoiceIntentKind.place);
      expect(h('7-11').kind, VoiceIntentKind.place);
    });

    test('place names lose the filler words', () {
      expect(h('我想去 NOVA').placeNames.first, 'NOVA');
      expect(h('帶我去台中車站').placeNames.first, '台中車站');
      expect(h('take me to Feng Chia University').placeNames.first,
          'Feng Chia University');
      expect(h('How do I get to Taichung Station?').placeNames.first,
          'Taichung Station');
      expect(h('逢甲大學怎麼走').placeNames.first, '逢甲大學');
    });
  });

  test('answers are cleaned before being read aloud', () {
    expect(VoiceService.cleanForSpeech('**Take** bus 27 🚌 → see https://x.y/z'),
        'Take bus 27 → see');
    expect(VoiceService.cleanForSpeech('## 步驟\n- 搭 306'), '步驟 - 搭 306');
  });

  test('the greeting waves with both hands', () {
    for (final k in signVocabulary['WELCOME']!.keys) {
      expect(k.left, isNotNull);
      // Both hands up at shoulder height, not resting below the frame.
      expect(k.pose.position.y, greaterThan(-2.5));
      expect(k.left!.position.y, greaterThan(-2.5));
    }
  });

  test('sign timeline JSON for the 3D avatar', () {
    final json = SignTimeline(['HELLO', 'nope', 'STOP'])
        .toJson(['HELLO', 'nope', 'STOP']);
    expect(json['spans'], hasLength(2));
    expect((json['spans'] as List)[1][2], 'STOP');
    for (final k in json['keys'] as List) {
      expect((k['r'] as List), hasLength(26));
      expect((k['l'] as List), hasLength(26));
    }
  });

  group('streaming tool loop (mocked API)', () {
    setUp(() => ClaudeApi.debugForceConfigured = true);
    tearDown(() => ClaudeApi.debugForceConfigured = false);

    test('rebuilds thinking + tool_use blocks, runs the tool, streams text',
        () async {
      final rounds = [
        _sse([
          {'type': 'message_start', 'message': {}},
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'thinking', 'thinking': ''},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'thinking_delta', 'thinking': 'plan'},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'signature_delta', 'signature': 'sig'},
          },
          {'type': 'content_block_stop', 'index': 0},
          {
            'type': 'content_block_start',
            'index': 1,
            'content_block': {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'plan_trip',
              'input': {},
            },
          },
          {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"destination_names": ["nova',
            },
          },
          {
            'type': 'content_block_delta',
            'index': 1,
            'delta': {'type': 'input_json_delta', 'partial_json': '"]}'},
          },
          {'type': 'content_block_stop', 'index': 1},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
          },
          {'type': 'message_stop'},
        ]),
        _sse([
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': 'Take bus '},
          },
          {
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': '27.'},
          },
          {'type': 'content_block_stop', 'index': 0},
          {
            'type': 'message_delta',
            'delta': {'stop_reason': 'end_turn'},
          },
        ]),
      ];
      final sentBodies = <Map<String, dynamic>>[];
      var call = 0;
      final client = MockClient.streaming((req, body) async {
        sentBodies.add(jsonDecode(await body.bytesToString())
            as Map<String, dynamic>);
        return http.StreamedResponse(
            Stream.value(utf8.encode(rounds[call++])), 200);
      });

      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'I want to go to nova'},
      ];
      Map<String, dynamic>? toolInput;
      final texts = await http.runWithClient(
        () => ClaudeApi.streamWithTools(
          system: 's',
          messages: messages,
          tools: [
            {'name': 'plan_trip', 'eager_input_streaming': true},
          ],
          runTool: (name, input) async {
            toolInput = input;
            return '{"route": "27"}';
          },
        ).toList(),
        () => client,
      );

      expect(texts.last, 'Take bus 27.');
      expect(toolInput, {
        'destination_names': ['nova'],
      });
      expect(messages, hasLength(4));
      final firstTurn = messages[1]['content'] as List;
      expect(firstTurn[0], {
        'type': 'thinking',
        'thinking': 'plan',
        'signature': 'sig',
      });
      expect(firstTurn[1]['input'], {
        'destination_names': ['nova'],
      });
      final results = messages[2]['content'] as List;
      expect(results.single['tool_use_id'], 'toolu_1');
      // The second request replays the first turn unchanged.
      expect((sentBodies[1]['messages'] as List)[1]['content'], firstTurn);
      expect((messages[3]['content'] as List).single['text'], 'Take bus 27.');
    });

    test('invalid streamed tool JSON goes back as an error result', () async {
      var call = 0;
      final client = MockClient.streaming((req, body) async {
        final events = call++ == 0
            ? _sse([
                {
                  'type': 'content_block_start',
                  'index': 0,
                  'content_block': {
                    'type': 'tool_use',
                    'id': 't',
                    'name': 'plan_trip',
                    'input': {},
                  },
                },
                {
                  'type': 'content_block_delta',
                  'index': 0,
                  'delta': {'type': 'input_json_delta', 'partial_json': '{"a'},
                },
                {'type': 'content_block_stop', 'index': 0},
                {
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'tool_use'},
                },
              ])
            : _sse([
                {
                  'type': 'content_block_start',
                  'index': 0,
                  'content_block': {'type': 'text', 'text': 'ok'},
                },
                {
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'end_turn'},
                },
              ]);
        return http.StreamedResponse(Stream.value(utf8.encode(events)), 200);
      });
      var ran = false;
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hi'},
      ];
      await http.runWithClient(
        () => ClaudeApi.streamWithTools(
          system: 's',
          messages: messages,
          runTool: (_, __) async {
            ran = true;
            return '';
          },
        ).toList(),
        () => client,
      );
      expect(ran, isFalse);
      final result = (messages[2]['content'] as List).single;
      expect(result['is_error'], isTrue);
      expect(result['content'], startsWith('INVALID_JSON'));
      // The private marker never reaches the API history.
      expect((messages[1]['content'] as List).single.containsKey('_invalid'),
          isFalse);
    });

    test('refusal surfaces as an error', () async {
      final client = MockClient.streaming((req, body) async =>
          http.StreamedResponse(
              Stream.value(utf8.encode(_sse([
                {
                  'type': 'message_delta',
                  'delta': {'stop_reason': 'refusal'},
                },
              ]))),
              200));
      expect(
        http.runWithClient(
          () => ClaudeApi.streamWithTools(
            system: 's',
            messages: [
              {'role': 'user', 'content': 'x'},
            ],
          ).toList(),
          () => client,
        ),
        throwsA(isA<ClaudeException>()),
      );
    });
  });
}
