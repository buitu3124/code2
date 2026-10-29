import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taiwan_bus_tracker/screens/ai_chat_screen.dart';
import 'package:taiwan_bus_tracker/screens/sign_assistant_screen.dart';
import 'package:taiwan_bus_tracker/services/sign_answer.dart';
import 'package:taiwan_bus_tracker/services/trip_planner.dart';
import 'package:taiwan_bus_tracker/utils/app_strings.dart';
import 'package:taiwan_bus_tracker/widgets/sign_hand/hand_model.dart';
import 'package:taiwan_bus_tracker/widgets/sign_hand/sign_hand_view.dart';
import 'package:taiwan_bus_tracker/widgets/sign_hand/sign_vocabulary.dart';

void main() {
  group('textToSigns', () {
    test('word signs, digit-by-digit numbers, fingerspelling', () {
      expect(textToSigns('Hello bus 52'), ['HELLO', 'BUS', '5', '2']);
      expect(textToSigns('cat'), ['C', 'A', 'T']);
      expect(textToSigns('thank you'), ['THANK_YOU']);
      expect(textToSigns('walk left'), ['WALK', 'LEFT']);
    });

    test('Chinese words match longest first', () {
      expect(textToSigns('你好，廁所在哪裡'), ['HELLO', 'TOILET', 'WHERE']);
      expect(textToSigns('不是'), ['NO']);
      expect(textToSigns('上車'), ['GET_ON']);
    });
  });

  test('every sign produces finite poses for both hands', () {
    for (final id in signVocabulary.keys) {
      final t = SignTimeline([id]);
      expect(t.spans, hasLength(1), reason: id);
      for (var ms = 0.0; ms <= t.totalMs; ms += 50) {
        final hands = t.poseAt(ms);
        for (final pose in [hands.right, hands.left]) {
          final skel = HandSkeleton.world(pose);
          for (final p in [...skel.thumb, ...skel.fingers.expand((f) => f)]) {
            expect(p.x.isFinite && p.y.isFinite && p.z.isFinite, isTrue,
                reason: id);
          }
        }
      }
    }
  });

  test('two-handed signs actually raise the left hand into view', () {
    for (final id in ['WALK', 'STOP', 'MINUTE', 'GET_ON', 'HELP', 'TRAIN']) {
      final left = signVocabulary[id]!.keys.last.left;
      expect(left, isNotNull, reason: id);
      expect(left!.position.y, greaterThan(-3.5), reason: id);
    }
  });

  test('thumb solver brings the thumb tip to the target finger', () {
    for (final id in ['O', 'F', 'D', '6', '7', '8', '9']) {
      final pose = signVocabulary[id]!.keys.last.pose;
      final skel = HandSkeleton.local(pose);
      final gaps = [
        for (final f in skel.fingers) (f.last - skel.thumb.last).length
      ];
      expect(gaps.reduce((a, b) => a < b ? a : b), lessThan(0.12),
          reason: id);
    }
  });

  group('trip → signed steps', () {
    // Shape of the real Google answer for "nova taichung store" from
    // Taichung Station.
    const plan = TripPlan(
      destination: 'NOVA',
      address: '403台灣臺中市西區英才路508號',
      distanceKm: 2.6,
      totalMinutes: 22,
      steps: [
        TripStep.walk(meters: 200, minutes: 3, toStop: '臺中車站A月台'),
        TripStep.bus(
          line: '306',
          headsign: '清水',
          fromStop: '臺中車站A月台',
          toStop: '中正國小[專用道]',
          numStops: 6,
          minutes: 12,
          liveEtaMins: 4,
        ),
        TripStep.walk(meters: 400, minutes: 6),
      ],
    );

    test('walk, bus with live ETA, ride, final walk', () {
      final a = tripToAnswer(plan, AppLanguage.zh);
      expect(a.steps.map((s) => s.pictogram),
          ['walk', 'bus', 'stop', 'flag']);
      expect(a.steps[0].signs, ['WALK', 'STOP', '3', 'MINUTE']);
      expect(a.steps[1].signs,
          ['BUS', '3', '0', '6', 'WAIT', '4', 'MINUTE', 'GET_ON']);
      expect(a.steps[1].bigText, '306 · 4 min');
      expect(a.steps[1].card, contains('中正國小'));
      expect(a.steps[2].signs, ['6', 'STOP', 'GET_OFF']);
      expect(a.reply, contains('306'));
      // Every sign is playable and maps back to its step.
      expect(a.allSigns.every(signVocabulary.containsKey), isTrue);
      expect(a.stepOfSign.length, a.allSigns.length);
    });

    test('answer survives a JSON round trip (as Claude returns it)', () {
      final a = tripToAnswer(plan, AppLanguage.en);
      final b = SignAnswer.fromJson(a.toJson());
      expect(b.allSigns, a.allSigns);
      expect(b.steps.map((s) => s.bigText), a.steps.map((s) => s.bigText));
    });

    test('route numbers: digits signed, letters spelled, Chinese skipped', () {
      expect(numberSigns('300區'), ['3', '0', '0']);
      expect(numberSigns('E1'), ['E', '1']);
    });
  });

  group('screens render without errors (AI not configured)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('sign assistant: phrasebook sign, local spelling, rotate',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: SignAssistantScreen())));
      await tester.pump(const Duration(milliseconds: 500));

      // Phrasebook sheet → 走路 (WALK, two-handed)
      await tester.tap(find.byIcon(Icons.sign_language_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('走路'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // Without a key, sending fingerspells locally and adds a turn.
      // The bottom bar is the last text field (the first searches places).
      await tester.enterText(find.byType(TextField).last, 'bus 52');
      await tester.tap(find.byIcon(Icons.back_hand_outlined));
      await tester.pump();
      expect(find.text('bus 52'), findsWidgets);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      await tester.drag(find.byType(SignHandView), const Offset(60, 0));
      await tester.pump(const Duration(seconds: 2)); // let gesture timers expire
      expect(tester.takeException(), isNull);
    });

    testWidgets('sign assistant: search any place, greet with both hands',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: SignAssistantScreen())));
      await tester.pump(const Duration(milliseconds: 300));
      // Opens with the two-handed greeting.
      expect(find.text('嗨，歡迎！'), findsWidgets);

      // Typing shows matching places at once (no AI, no network needed).
      await tester.enterText(find.byType(TextField).first, '逢甲');
      await tester.pump();
      expect(find.widgetWithText(ListTile, '逢甲大學'), findsOneWidget);

      // Let the debounced online search run (fails offline in tests).
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 10));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('chat screen shows the not-configured banner',
        (tester) async {
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: AiChatScreen())));
      await tester.pump();
      expect(find.textContaining('API'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
