// Tools the AI assistant can call, shared by the chat, the sign-language
// assistant and voice commands.

import 'dart:convert';
import '../utils/app_strings.dart';
import 'assistant_context.dart';
import 'sign_answer.dart';
import 'trip_planner.dart';

/// Tool definition for plan_trip. Set [streaming] for streamed requests so
/// the input streams eagerly (it is then validated in [runPlanTrip]).
Map<String, dynamic> planTripTool({bool streaming = false}) => {
      'name': 'plan_trip',
      'description':
          "Plans a bus trip from the passenger's current GPS position to a "
              'destination in or near Taichung, Taiwan. Returns the '
              'destination that was found (name, address, straight-line '
              'distance), the steps (walk, or bus with route number, '
              'boarding stop, stop to get off at and number of stops), the '
              'live arrival time of the first bus when available, and '
              'suggested_steps already converted to signs. Returns an error '
              'when the location is unknown or no route exists.',
      'strict': true,
      if (streaming) 'eager_input_streaming': true,
      'input_schema': {
        'type': 'object',
        'properties': {
          'destination_names': {
            'type': 'array',
            'items': {'type': 'string'},
            'description':
                'Names to try, best first: the passenger\'s wording plus the '
                    'official English / Traditional Chinese names if known, '
                    'e.g. ["nova taichung store", "NOVA 資訊廣場 台中"].',
          },
        },
        'required': ['destination_names'],
        'additionalProperties': false,
      },
    };

/// Executes plan_trip and returns the JSON tool result.
Future<String> runPlanTrip(
    Map<String, dynamic> input, AppLanguage lang) async {
  final raw = input['destination_names'];
  if (raw is! List) {
    return jsonEncode({'error': 'destination_names must be a list'});
  }
  final names = [
    for (final n in raw)
      if (n is String && n.trim().isNotEmpty) n.trim(),
  ];
  if (names.isEmpty) return jsonEncode({'error': 'no destination given'});
  final origin = await AssistantContext.position();
  if (origin == null) {
    return jsonEncode({
      'error': "The passenger's location is unknown. Ask them to turn on "
          'location for this app.',
    });
  }
  final plan = await TripPlanner.plan(origin: origin, queries: names);
  if (plan == null) {
    return jsonEncode({'error': 'No place or bus route found for $names.'});
  }
  return jsonEncode({
    ...plan.toJson(),
    'suggested_steps': tripToAnswer(plan, lang).toJson()['steps'],
  });
}
