// What the sign-language assistant shows for one answer: a list of steps,
// each with a pictogram, one big line (route number, stop name), a short
// text for helpers, the signs the hands perform, and optionally a card the
// passenger can show to the bus driver.
//
// [tripToAnswer] builds this straight from a [TripPlan] without AI, so the
// route numbers and stop names always come from real data.

import '../utils/app_strings.dart';
import '../widgets/sign_hand/sign_vocabulary.dart';
import 'trip_planner.dart';

class SignStep {
  final String pictogram;
  final String bigText;
  final String text;
  final List<String> signs;

  /// Text to show the driver or staff; '' when not needed.
  final String card;

  const SignStep({
    required this.pictogram,
    required this.bigText,
    required this.text,
    required this.signs,
    this.card = '',
  });

  factory SignStep.fromJson(Map<String, dynamic> j) => SignStep(
        pictogram: j['pictogram'] as String? ?? 'help',
        bigText: j['big_text'] as String? ?? '',
        text: j['text'] as String? ?? '',
        signs: [
          for (final s in (j['signs'] as List? ?? const []))
            if (signVocabulary.containsKey(s)) s as String,
        ],
        card: j['card'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'pictogram': pictogram,
        'big_text': bigText,
        'text': text,
        'signs': signs,
        'card': card,
      };
}

class SignAnswer {
  final String reply;
  final List<SignStep> steps;

  const SignAnswer({required this.reply, required this.steps});

  factory SignAnswer.fromJson(Map<String, dynamic> j) => SignAnswer(
        reply: j['reply'] as String? ?? '',
        steps: [
          for (final s in (j['steps'] as List? ?? const []))
            SignStep.fromJson(s as Map<String, dynamic>),
        ],
      );

  Map<String, dynamic> toJson() => {
        'reply': reply,
        'steps': [for (final s in steps) s.toJson()],
      };

  /// All signs in order, and for each sign the step it belongs to.
  List<String> get allSigns => [for (final s in steps) ...s.signs];
  List<int> get stepOfSign => [
        for (var i = 0; i < steps.length; i++)
          for (final _ in steps[i].signs) i,
      ];
}

/// Signs for a route number or count: digits one by one, Latin letters
/// fingerspelled, anything else (e.g. 區, 副) skipped.
List<String> numberSigns(String s) => [
      for (final ch in s.toUpperCase().split(''))
        if (signVocabulary.containsKey(ch)) ch,
    ];

/// JSON schema for Claude's answers (structured outputs).
Map<String, dynamic> signAnswerSchema(Iterable<String> pictograms) => {
      'type': 'object',
      'properties': {
        'reply': {'type': 'string'},
        'steps': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'pictogram': {'type': 'string', 'enum': pictograms.toList()},
              'big_text': {'type': 'string'},
              'text': {'type': 'string'},
              'signs': {
                'type': 'array',
                'items': {
                  'type': 'string',
                  'enum': signVocabulary.keys.toList(),
                },
              },
              'card': {'type': 'string'},
            },
            'required': ['pictogram', 'big_text', 'text', 'signs', 'card'],
            'additionalProperties': false,
          },
        },
      },
      'required': ['reply', 'steps'],
      'additionalProperties': false,
    };

SignAnswer tripToAnswer(TripPlan plan, AppLanguage lang) {
  final zh = lang == AppLanguage.zh;
  final steps = <SignStep>[];
  var buses = 0;

  for (var i = 0; i < plan.steps.length; i++) {
    final s = plan.steps[i];
    final isLast = i == plan.steps.length - 1;
    final mins = numberSigns('${s.minutes}');

    if (s.kind == TripStepKind.walk) {
      if (isLast) {
        steps.add(SignStep(
          pictogram: 'flag',
          bigText: '${s.meters} m → ${plan.destination}',
          text: zh
              ? '步行 ${s.meters} 公尺（約 ${s.minutes} 分鐘）到 ${plan.destination}'
              : 'Walk ${s.meters} m (about ${s.minutes} min) to ${plan.destination}',
          signs: ['WALK', 'THERE', ...mins, 'MINUTE'],
        ));
      } else {
        steps.add(SignStep(
          pictogram: 'walk',
          bigText: '${s.meters} m → ${s.toStop ?? ''}',
          text: zh
              ? '步行 ${s.meters} 公尺（約 ${s.minutes} 分鐘）到「${s.toStop}」站'
              : 'Walk ${s.meters} m (about ${s.minutes} min) to the stop "${s.toStop}"',
          signs: ['WALK', 'STOP', ...mins, 'MINUTE'],
        ));
      }
      continue;
    }

    // Bus: board…
    buses++;
    final line = s.line ?? '?';
    final eta = s.liveEtaMins;
    steps.add(SignStep(
      pictogram: 'bus',
      bigText: eta == null ? line : '$line · $eta min',
      text: zh
          ? '${buses > 1 ? '轉乘' : '搭'} $line 號公車（往 ${s.headsign ?? ''}）'
              '${eta == null ? '' : '，約 $eta 分鐘後到站'}'
          : '${buses > 1 ? 'Change to' : 'Take'} bus $line '
              '(towards ${s.headsign ?? ''})'
              '${eta == null ? '' : ', arriving in about $eta min'}',
      signs: [
        if (buses > 1) 'CHANGE',
        'BUS',
        ...numberSigns(line),
        if (eta != null) ...['WAIT', ...numberSigns('$eta'), 'MINUTE'],
        'GET_ON',
      ],
      card: '我要搭 $line 號公車到「${s.toStop}」，到站時請提醒我下車，謝謝！\n'
          'I am taking bus $line to "${s.toStop}". '
          'Please tell me when to get off. Thank you!',
    ));
    // …ride and get off.
    steps.add(SignStep(
      pictogram: 'stop',
      bigText: '${s.numStops} → ${s.toStop ?? ''}',
      text: zh
          ? '坐 ${s.numStops} 站，在「${s.toStop}」下車'
          : 'Ride ${s.numStops} stops, get off at "${s.toStop}"',
      signs: [...numberSigns('${s.numStops}'), 'STOP', 'GET_OFF'],
    ));
  }

  if (steps.isEmpty || steps.last.pictogram != 'flag') {
    steps.add(SignStep(
      pictogram: 'flag',
      bigText: plan.destination,
      text: zh ? '到達 ${plan.destination}' : 'Arrive at ${plan.destination}',
      signs: const ['THERE'],
    ));
  }

  final lines = [for (final b in plan.busSteps) b.line ?? '?'].join(' → ');
  final reply = plan.busSteps.isEmpty
      ? (zh
          ? '${plan.destination} 很近，步行約 ${plan.totalMinutes} 分鐘。'
          : '${plan.destination} is close: about ${plan.totalMinutes} min on foot.')
      : (zh
          ? '去 ${plan.destination}：搭 $lines 號公車，全程約 ${plan.totalMinutes} 分鐘。'
          : 'To ${plan.destination}: take bus $lines, about ${plan.totalMinutes} min in total.');
  return SignAnswer(reply: reply, steps: steps);
}
