// Sign vocabulary for the 3D hand.
//
// Handshapes follow American Sign Language (ASL) fingerspelling and numbers,
// plus common words — including two-handed ones used for bus directions
// (WALK, STOP, GET-ON, MINUTE, …). They are approximations without facial
// expression or body contact, so treat them as a visual aid and have them
// reviewed by Deaf signers before relying on them. Taiwan Sign
// Language (TSL) uses different handshapes; a TSL set can be added here with
// the same structure.

import 'hand_model.dart';

/// One keyframe of a sign: the poses to reach and how long the move takes.
class SignKey {
  /// Dominant (right) hand.
  final HandPose pose;
  final int moveMs;

  /// Left hand, authored like a right hand on the mirrored side (see
  /// [buildScenePrims]); null = lowered out of view.
  final HandPose? left;

  const SignKey(this.pose, [this.moveMs = 260, this.left]);
}

class SignDef {
  final String id;
  final String en;
  final String zh;
  final List<SignKey> keys;

  /// How long the final pose is held before the next sign.
  final int holdMs;

  const SignDef(this.id, this.en, this.zh, this.keys, {this.holdMs = 650});
}

// ─── Finger / thumb building blocks ──────────────────────────────────────────

const _straight = FingerPose(0, 0, 0);
const _fist = FingerPose(88, 100, 62);
const _curve = FingerPose(28, 40, 26); // C
const _round = FingerPose(65, 80, 45); // O: tips curl back to meet the thumb
const _hook = FingerPose(10, 95, 70); // X
const _claw = FingerPose(68, 105, 78); // E
const _drape = FingerPose(80, 85, 45); // M / N over the thumb

const _tAlong = ThumbPose(8, 18); // A: beside the index
const _tUp = ThumbPose(12, 30); // 10 / thumbs-up
const _tAcross = ThumbPose(-58, 55, 25, 20); // S: over the curled fingers
const _tTuck = ThumbPose(-32, 30, 38, 22); // B / 4: folded across the palm
const _tOut = ThumbPose(55, 12); // L, 5, Y
const _tUnder = ThumbPose(-35, 10); // M / N: under the fingers
const _tE = ThumbPose(-55, 28, 32, 20);
const _tK = ThumbPose(-6, 48); // K / P: up between index and middle
const _tT = ThumbPose(-14, 38, 12, 0); // T: between index and middle
const _tC = ThumbPose(12, 52, 18, 12);

List<FingerPose> _f(FingerPose i, FingerPose m, FingerPose r, FingerPose p) =>
    [i, m, r, p];

HandPose _h(List<FingerPose> f, ThumbPose t,
        {double yaw = 0, double pitch = 0, double roll = -6}) =>
    HandPose(fingers: f, thumb: t, yaw: yaw, pitch: pitch, roll: roll);

final _allFist = _f(_fist, _fist, _fist, _fist);

/// Relaxed open right hand shown before and after a sequence.
const restPose = HandPose(
  fingers: [
    FingerPose(14, 14, 8, 6),
    FingerPose(16, 16, 8, 0),
    FingerPose(18, 18, 10, -5),
    FingerPose(20, 20, 10, -12),
  ],
  thumb: ThumbPose(30, 25, 10, 5),
  pitch: -10,
  roll: -12,
);

/// Left hand when a sign doesn't use it: hanging at the side, fingers
/// down, palm toward the thigh (below the 2D renderer's frame).
final leftRest = restPose.copyWith(
    position: const Vec3(-2.3, -6.0, 0.1), roll: 180, yaw: 90, pitch: 0);

// ─── Handshapes ──────────────────────────────────────────────────────────────

final Map<String, HandPose> _shapes = {
  'A': _h(_allFist, _tAlong),
  'B': _h(_f(_straight, _straight, _straight, _straight), _tTuck),
  'C': _h(_f(_curve, _curve, _curve, _curve), _tC, yaw: 70),
  'D': _h(_f(_straight, _round, _round, _round), _tC).thumbTouching(1),
  'E': _h(_f(_claw, _claw, _claw, _claw), _tE),
  'F': _h(
          _f(_round, _straight.withSpread(4), _straight.withSpread(-4),
              _straight.withSpread(-12)),
          _tC)
      .thumbTouching(0),
  'G': _h(_f(_straight, _fist, _fist, _fist), const ThumbPose(28, 10),
      yaw: 160, roll: 80),
  'H': _h(_f(_straight, _straight, _fist, _fist), _tTuck, yaw: 160, roll: 80),
  'I': _h(_f(_fist, _fist, _fist, _straight), _tAcross),
  'K': _h(
      _f(_straight.withSpread(8), const FingerPose(38, 0, 0, -10), _fist,
          _fist),
      _tK),
  'L': _h(_f(_straight, _fist, _fist, _fist), _tOut),
  'M': _h(_f(_drape, _drape, _drape, _fist), _tUnder),
  'N': _h(_f(_drape, _drape, _fist, _fist), _tUnder),
  'O': _h(_f(_round, _round, _round, _round), _tC, yaw: 55).thumbTouching(1),
  'P': _h(
      _f(_straight.withSpread(8), const FingerPose(45, 0, 0, -10), _fist,
          _fist),
      _tK,
      pitch: 130),
  'Q': _h(_f(_straight, _fist, _fist, _fist), const ThumbPose(28, 10),
      pitch: 140, yaw: -20),
  'R': _h(
      _f(const FingerPose(0, 0, 0, -9), const FingerPose(4, 0, 0, 10), _fist,
          _fist),
      _tAcross),
  'S': _h(_allFist, _tAcross),
  'T': _h(_f(const FingerPose(70, 75, 35), _fist, _fist, _fist), _tT),
  'U': _h(_f(_straight, _straight, _fist, _fist), _tAcross),
  'V': _h(
      _f(_straight.withSpread(10), _straight.withSpread(-10), _fist, _fist),
      _tAcross),
  'W': _h(
          _f(_straight.withSpread(12), _straight, _straight.withSpread(-12),
              const FingerPose(55, 60, 40)),
          _tC)
      .thumbTouching(3),
  'X': _h(_f(_hook, _fist, _fist, _fist), _tAcross),
  'Y': _h(_f(_fist, _fist, _fist, _straight.withSpread(-25)), _tOut),

  // Numbers (palm toward the signer for 1–5, as in ASL)
  '1': _h(_f(_straight, _fist, _fist, _fist), _tAcross, yaw: 180),
  '2': _h(
      _f(_straight.withSpread(10), _straight.withSpread(-10), _fist, _fist),
      _tAcross,
      yaw: 180),
  '3': _h(
      _f(_straight.withSpread(10), _straight.withSpread(-8), _fist, _fist),
      _tOut,
      yaw: 180),
  '4': _h(
      _f(_straight.withSpread(9), _straight.withSpread(3),
          _straight.withSpread(-3), _straight.withSpread(-10)),
      _tTuck,
      yaw: 180),
  '5': _h(
      _f(_straight.withSpread(10), _straight.withSpread(2),
          _straight.withSpread(-6), _straight.withSpread(-18)),
      _tOut,
      yaw: 180),
  '6': _h(
          _f(_straight.withSpread(12), _straight, _straight.withSpread(-12),
              const FingerPose(55, 60, 40)),
          _tC)
      .thumbTouching(3),
  '7': _h(
          _f(_straight.withSpread(12), _straight.withSpread(2),
              const FingerPose(55, 60, 40), _straight.withSpread(-18)),
          _tC)
      .thumbTouching(2),
  '8': _h(
          _f(_straight.withSpread(12), const FingerPose(55, 60, 40),
              _straight.withSpread(-6), _straight.withSpread(-18)),
          _tC)
      .thumbTouching(1),
  '9': _h(
          _f(const FingerPose(55, 60, 40), _straight.withSpread(4),
              _straight.withSpread(-6), _straight.withSpread(-18)),
          _tC)
      .thumbTouching(0),
};

HandPose _shape(String id) => _shapes[id]!;

/// Static handshape held in the fingerspelling position.
SignDef _static(String id, String en, String zh) =>
    SignDef(id, en, zh, [SignKey(_shape(id))]);

/// Offsets from [HandPose.neutral] that bring an upright hand's fingertips
/// to the chin / forehead, or the palm onto the chest.
const _atChin = Vec3(1.0, 0.4, -0.7);
const _atChest = Vec3(0.7, 0.2, -0.9);
const _atForehead = Vec3(0.7, 1.6, -0.7);

// ─── Vocabulary ──────────────────────────────────────────────────────────────

final Map<String, SignDef> signVocabulary = () {
  final v = <String, SignDef>{};
  for (final l in 'ABCDEFGHIKLMNOPQRSTUVWXY'.split('')) {
    v[l] = _static(l, l, l);
  }
  for (final d in '0123456789'.split('')) {
    v[d] = d == '0'
        ? SignDef('0', '0', '0', [SignKey(_shape('O'))])
        : _static(d, d, d);
  }

  // J: the I-hand traces a hook downward.
  final i = _shape('I');
  v['J'] = SignDef('J', 'J', 'J', [
    SignKey(i),
    SignKey(i.moved(by: const Vec3(0, -0.4, 0), roll: 30), 220),
    SignKey(i.moved(by: const Vec3(0.35, -0.55, 0.2), roll: 85, yaw: 30), 220),
  ]);

  // Z: the index finger draws a Z.
  final z = _shape('1').copyWith(yaw: 0, pitch: 25);
  v['Z'] = SignDef('Z', 'Z', 'Z', [
    SignKey(z.moved(by: const Vec3(-0.4, 0.3, 0))),
    SignKey(z.moved(by: const Vec3(0.4, 0.3, 0)), 200),
    SignKey(z.moved(by: const Vec3(-0.4, -0.3, 0)), 220),
    SignKey(z.moved(by: const Vec3(0.4, -0.3, 0)), 200),
  ]);

  // 10: thumbs-up, shaken.
  final ten = _h(_allFist, _tUp);
  v['10'] = SignDef('10', '10', '10', [
    SignKey(ten.moved(roll: -15)),
    SignKey(ten.moved(roll: 15), 160),
    SignKey(ten.moved(roll: -15), 160),
    SignKey(ten.moved(roll: 15), 160),
  ]);

  // HELLO: flat hand from the forehead, outward.
  final b = _shape('B');
  v['HELLO'] = SignDef('HELLO', 'Hello', '你好', [
    SignKey(b.moved(by: _atForehead, roll: 20)),
    SignKey(b.moved(by: _atForehead + const Vec3(-1.0, -0.1, 0.4), roll: -5),
        380),
  ]);

  // THANK YOU: fingertips at the chin, hand moves forward and down.
  final ty = b.copyWith(yaw: 180, roll: 0);
  v['THANK_YOU'] = SignDef('THANK_YOU', 'Thank you', '謝謝', [
    SignKey(ty.moved(by: _atChin)),
    SignKey(ty.moved(by: _atChin + const Vec3(0, -0.6, 1.6), pitch: -55), 450),
  ]);

  // YES: S-hand nodding.
  final s = _shape('S');
  v['YES'] = SignDef('YES', 'Yes', '是', [
    SignKey(s),
    SignKey(s.moved(pitch: 40), 180),
    SignKey(s, 180),
    SignKey(s.moved(pitch: 40), 180),
  ]);

  // NO: index + middle snap onto the thumb, twice.
  final noOpen = _h(_f(_straight, _straight, _fist, _fist),
      const ThumbPose(40, 30), pitch: 20);
  final noClosed = _h(
          _f(const FingerPose(45, 30, 20), const FingerPose(45, 30, 20),
              _fist, _fist),
          _tC,
          pitch: 20)
      .thumbTouching(1);
  v['NO'] = SignDef('NO', 'No', '不是', [
    SignKey(noOpen),
    SignKey(noClosed, 170),
    SignKey(noOpen, 170),
    SignKey(noClosed, 170),
  ]);

  // WHERE: index finger wagging side to side.
  final one = _shape('1').copyWith(yaw: 0);
  v['WHERE'] = SignDef('WHERE', 'Where?', '哪裡？', [
    SignKey(one.moved(roll: -18)),
    SignKey(one.moved(roll: 18), 200),
    SignKey(one.moved(roll: -18), 200),
    SignKey(one.moved(roll: 18), 200),
  ]);

  // WAIT: both open hands, palms up, fingers wiggling.
  final waitA = _h(
      _f(const FingerPose(10, 5, 0, 10), const FingerPose(35, 20, 10, 2),
          const FingerPose(10, 5, 0, -6), const FingerPose(35, 20, 10, -18)),
      _tOut,
      pitch: -55);
  final waitB = _h(
      _f(const FingerPose(35, 20, 10, 10), const FingerPose(10, 5, 0, 2),
          const FingerPose(35, 20, 10, -6), const FingerPose(10, 5, 0, -18)),
      _tOut,
      pitch: -55);
  final waitL = waitA.moved(by: const Vec3(-0.3, -0.3, 0));
  final waitLB = waitB.moved(by: const Vec3(-0.3, -0.3, 0));
  v['WAIT'] = SignDef('WAIT', 'Wait', '等一下', [
    SignKey(waitA, 260, waitLB),
    SignKey(waitB, 150, waitL),
    SignKey(waitA, 150, waitLB),
    SignKey(waitB, 150, waitL),
  ]);

  // PLEASE / SORRY: flat hand / fist circling on the chest.
  SignDef circling(String id, String en, String zh, HandPose shape) {
    // Yaw 180 mirrors the roll: +60 points the fingers to the signer's left.
    final p = shape.copyWith(yaw: 180, roll: 60).moved(by: _atChest);
    return SignDef(id, en, zh, [
      SignKey(p),
      SignKey(p.moved(by: const Vec3(0.35, 0.3, 0)), 200),
      SignKey(p.moved(by: const Vec3(0.7, 0, 0)), 200),
      SignKey(p.moved(by: const Vec3(0.35, -0.3, 0)), 200),
      SignKey(p, 200),
    ]);
  }

  v['PLEASE'] = circling('PLEASE', 'Please', '請', b);
  v['SORRY'] = circling('SORRY', 'Sorry', '對不起', _shape('A'));

  // TOILET: T-hand shaken side to side.
  final t = _shape('T');
  v['TOILET'] = SignDef('TOILET', 'Toilet', '廁所', [
    SignKey(t.moved(by: const Vec3(-0.15, 0, 0))),
    SignKey(t.moved(by: const Vec3(0.15, 0, 0)), 150),
    SignKey(t.moved(by: const Vec3(-0.15, 0, 0)), 150),
    SignKey(t.moved(by: const Vec3(0.15, 0, 0)), 150),
  ]);

  // WATER: W-hand tapping the chin.
  final w = _shape('W').moved(by: _atChin);
  v['WATER'] = SignDef('WATER', 'Water', '水', [
    SignKey(w),
    SignKey(w.moved(by: const Vec3(0, 0, 0.3)), 150),
    SignKey(w, 150),
  ]);

  // BUS: B then the number of a route is signed after it.
  v['BUS'] = SignDef('BUS', 'Bus', '公車', [
    SignKey(b),
    SignKey(_shape('U')),
    SignKey(_shape('S')),
  ]);

  // ── Two-handed and direction signs ─────────────────────────────────────

  // WELCOME: both open hands raised beside the face, waving hello.
  final wave = _h(
          _f(_straight.withSpread(10), _straight.withSpread(2),
              _straight.withSpread(-6), _straight.withSpread(-16)),
          _tOut)
      .copyWith(position: const Vec3(-2.05, -1.75, 0.9));
  final waveOut = wave.copyWith(roll: -24);
  final waveIn = wave.copyWith(roll: 8);
  v['WELCOME'] = SignDef('WELCOME', 'Hi, welcome!', '嗨，歡迎！', [
    SignKey(waveOut, 420, waveOut),
    SignKey(waveIn, 260, waveIn),
    SignKey(waveOut, 260, waveOut),
    SignKey(waveIn, 260, waveIn),
    SignKey(waveOut, 260, waveOut),
  ], holdMs: 300);

  // Left flat hand, palm up, fingers toward the body's centre: the base
  // that STOP, HELP and similar signs act on.
  final palmUp = b.copyWith(
      roll: -90, pitch: -65, position: const Vec3(-1.25, -2.75, 1.0));

  // Right flat hand, palm facing the signer's left, fingers forward,
  // thumb up — the "chopping" / "straight ahead" hand.
  final blade = b.copyWith(roll: 90, yaw: 120, pitch: 0);

  // STOP (also: bus stop): blade chops down onto the left palm.
  v['STOP'] = SignDef('STOP', 'Stop', '站', [
    SignKey(blade.copyWith(position: const Vec3(-0.35, -1.6, 0.8)), 340,
        palmUp),
    SignKey(blade.copyWith(position: const Vec3(-0.35, -2.4, 0.8)), 200,
        palmUp),
  ]);

  // WALK: both flat hands, palms down, stepping forward in turn.
  final step = b.copyWith(pitch: 80, roll: -25);
  final stepUp = step.copyWith(position: const Vec3(-0.8, -2.0, 1.2));
  final stepDown =
      step.copyWith(pitch: 105, position: const Vec3(-0.8, -2.45, 0.6));
  v['WALK'] = SignDef('WALK', 'Walk', '走路', [
    SignKey(stepUp, 300, stepDown),
    SignKey(stepDown, 220, stepUp),
    SignKey(stepUp, 220, stepDown),
    SignKey(stepDown, 220, stepUp),
  ]);

  // MINUTE: index finger ticks forward against the left palm (a clock).
  final clockFace =
      b.copyWith(yaw: 40, roll: 0, position: const Vec3(-0.9, -2.6, 0.6));
  final hand1 = _shape('1').copyWith(yaw: 0, roll: -10);
  v['MINUTE'] = SignDef('MINUTE', 'Minute', '分鐘', [
    SignKey(hand1.copyWith(position: const Vec3(0.55, -2.55, 1.1)), 340,
        clockFace),
    SignKey(
        hand1.copyWith(position: const Vec3(0.55, -2.55, 1.1), roll: -55),
        300,
        clockFace),
  ]);

  // GET ON / GET OFF: bent-V "legs" enter / leave the left C "vehicle".
  final vehicle = _shape('C').copyWith(position: const Vec3(-0.95, -2.6, 0.8));
  // Fingers hang down like legs: hand tipped over, palm toward the signer.
  final legs = _h(
      _f(const FingerPose(20, 45, 20, 8), const FingerPose(20, 45, 20, -8),
          _fist, _fist),
      _tAcross,
      pitch: 165,
      yaw: 15);
  final legsOut = legs.copyWith(position: const Vec3(-0.1, -0.9, 1.0));
  final legsIn = legs.copyWith(position: const Vec3(0.45, -1.75, 0.8));
  v['GET_ON'] = SignDef('GET_ON', 'Get on', '上車', [
    SignKey(legsOut, 340, vehicle),
    SignKey(legsIn, 380, vehicle),
  ]);
  v['GET_OFF'] = SignDef('GET_OFF', 'Get off', '下車', [
    SignKey(legsIn, 340, vehicle),
    SignKey(legsOut, 380, vehicle),
  ]);

  // GO: both index fingers arc forward.
  final point = _shape('1').copyWith(yaw: 0, roll: 0);
  final goStart =
      point.copyWith(pitch: -10, position: const Vec3(-0.85, -2.3, 0.4));
  final goEnd =
      point.copyWith(pitch: 70, position: const Vec3(-0.8, -2.4, 1.6));
  v['GO'] = SignDef('GO', 'Go', '去', [
    SignKey(goStart, 340, goStart),
    SignKey(goEnd, 380, goEnd),
  ]);

  // THERE: index points out and away.
  v['THERE'] = SignDef('THERE', 'There', '那裡', [
    SignKey(point.copyWith(pitch: 30, yaw: -20)),
    SignKey(
        point.copyWith(pitch: 65, yaw: -45).moved(by: const Vec3(-0.3, 0, 0.5)),
        300),
  ]);

  // LEFT / RIGHT: L-hand moves to the signer's left, R-hand to the right.
  final l = _shape('L');
  v['LEFT'] = SignDef('LEFT', 'Left', '左', [
    SignKey(l.moved(by: const Vec3(0.3, 0, 0))),
    SignKey(l.moved(by: const Vec3(1.1, 0, 0)), 380),
  ]);
  final r = _shape('R');
  v['RIGHT'] = SignDef('RIGHT', 'Right', '右', [
    SignKey(r.moved(by: const Vec3(0.2, 0, 0))),
    SignKey(r.moved(by: const Vec3(-0.6, 0, 0)), 380),
  ]);

  // STRAIGHT: the blade hand moves straight forward.
  v['STRAIGHT'] = SignDef('STRAIGHT', 'Straight ahead', '直走', [
    SignKey(blade.copyWith(position: const Vec3(-0.6, -2.2, 0.2))),
    SignKey(blade.copyWith(position: const Vec3(-0.6, -2.2, 1.7)), 420),
  ]);

  // HELP: thumbs-up fist on the left palm, both lift together.
  final helper = ten.copyWith(roll: 0, position: const Vec3(0.2, -2.55, 1.0));
  v['HELP'] = SignDef('HELP', 'Help', '幫忙', [
    SignKey(helper, 340, palmUp),
    SignKey(helper.moved(by: const Vec3(0, 0.6, 0)), 380,
        palmUp.moved(by: const Vec3(0, 0.6, 0))),
  ]);

  // CHANGE (transfer): both X hands twist around each other.
  final xHand = _shape('X').copyWith(yaw: 60);
  v['CHANGE'] = SignDef('CHANGE', 'Change bus', '轉乘', [
    SignKey(xHand.copyWith(position: const Vec3(-0.55, -2.4, 0.9), roll: 20),
        340, xHand.copyWith(position: const Vec3(-0.55, -2.6, 0.8), roll: 20)),
    SignKey(xHand.copyWith(position: const Vec3(-0.55, -2.6, 0.9), roll: 160),
        380, xHand.copyWith(position: const Vec3(-0.55, -2.4, 0.8), roll: 160)),
  ]);

  // TRAIN: right H slides back and forth along the left H.
  final hFlat = _shape('H').copyWith(yaw: 0, roll: -90, pitch: 80);
  final trainBase = hFlat.copyWith(position: const Vec3(-1.3, -2.65, 0.8));
  v['TRAIN'] = SignDef('TRAIN', 'Train', '火車', [
    SignKey(hFlat.copyWith(position: const Vec3(-1.15, -2.45, 0.9)), 340,
        trainBase),
    SignKey(hFlat.copyWith(position: const Vec3(-0.85, -2.45, 0.9)), 200,
        trainBase),
    SignKey(hFlat.copyWith(position: const Vec3(-1.15, -2.45, 0.9)), 200,
        trainBase),
  ]);

  // NOW: both Y hands, palms up, drop slightly.
  final yUp =
      _shape('Y').copyWith(pitch: -65, position: const Vec3(-0.9, -2.1, 0.8));
  v['NOW'] = SignDef('NOW', 'Now', '現在', [
    SignKey(yUp, 340, yUp),
    SignKey(yUp.moved(by: const Vec3(0, -0.45, 0)), 260,
        yUp.moved(by: const Vec3(0, -0.45, 0))),
  ]);

  // I / YOU: index points at the chest / at the viewer.
  v['I'] = SignDef('I', 'I / me', '我', [
    SignKey(
        point.copyWith(pitch: -80, position: const Vec3(-0.35, -2.75, 1.4))),
  ]);
  v['YOU'] = SignDef('YOU', 'You', '你', [
    SignKey(point.copyWith(pitch: 80, position: const Vec3(-0.7, -2.2, 0.8))),
  ]);

  return v;
}();

/// Word signs offered as quick buttons (ids into [signVocabulary]).
const quickWordSigns = [
  'HELLO', 'THANK_YOU', 'YES', 'NO', 'HELP', 'WHERE', 'WAIT', 'BUS', 'STOP',
  'GET_ON', 'GET_OFF', 'WALK', 'TRAIN', 'TOILET', 'WATER', 'PLEASE', 'SORRY',
];

/// Turns free text into sign ids: known words become word signs, numbers
/// are signed digit by digit and anything else is fingerspelled.
List<String> textToSigns(String text) {
  const wordMap = {
    'HELLO': 'HELLO', 'HI': 'HELLO', 'WELCOME': 'WELCOME', 'THANKS': 'THANK_YOU',
    'THANK': 'THANK_YOU', 'YES': 'YES', 'NO': 'NO', 'WHERE': 'WHERE',
    'WAIT': 'WAIT', 'BUS': 'BUS', 'TOILET': 'TOILET', 'BATHROOM': 'TOILET',
    'WATER': 'WATER', 'PLEASE': 'PLEASE', 'SORRY': 'SORRY',
    'STOP': 'STOP', 'WALK': 'WALK', 'MINUTE': 'MINUTE', 'MINUTES': 'MINUTE',
    'MIN': 'MINUTE', 'LEFT': 'LEFT', 'RIGHT': 'RIGHT', 'STRAIGHT': 'STRAIGHT',
    'THERE': 'THERE', 'HELP': 'HELP', 'TRAIN': 'TRAIN', 'NOW': 'NOW',
    'GO': 'GO', 'I': 'I', 'ME': 'I', 'YOU': 'YOU', 'CHANGE': 'CHANGE',
    '你好': 'HELLO', '歡迎': 'WELCOME', '謝謝': 'THANK_YOU', '是': 'YES', '不是': 'NO',
    '哪裡': 'WHERE', '等': 'WAIT', '公車': 'BUS', '廁所': 'TOILET',
    '水': 'WATER', '請': 'PLEASE', '對不起': 'SORRY',
    '站': 'STOP', '走路': 'WALK', '分鐘': 'MINUTE', '左': 'LEFT', '右': 'RIGHT',
    '直走': 'STRAIGHT', '那裡': 'THERE', '幫忙': 'HELP', '火車': 'TRAIN',
    '現在': 'NOW', '去': 'GO', '我': 'I', '你': 'YOU', '轉乘': 'CHANGE',
    '上車': 'GET_ON', '下車': 'GET_OFF',
  };
  final out = <String>[];
  final tokens = RegExp(r'[A-Za-z]+|\d+|[一-鿿]+')
      .allMatches(text)
      .map((m) => m.group(0)!);
  String? prev;
  for (final raw in tokens) {
    final word = raw.toUpperCase();
    final afterThank = prev == 'THANK' || prev == 'THANKS';
    prev = word;
    if (wordMap.containsKey(word)) {
      // "thank you" is one sign.
      if (word == 'YOU' && afterThank) continue;
      out.add(wordMap[word]!);
    } else if (RegExp(r'^\d+$').hasMatch(word)) {
      out.addAll(word.split(''));
    } else if (RegExp(r'^[A-Z]+$').hasMatch(word)) {
      out.addAll(word.split(''));
    } else {
      // Chinese run: greedy longest match against the known words.
      var i = 0;
      while (i < word.length) {
        var matched = false;
        for (var len = 3; len >= 1 && !matched; len--) {
          if (i + len > word.length) continue;
          final id = wordMap[word.substring(i, i + len)];
          if (id != null) {
            out.add(id);
            i += len;
            matched = true;
          }
        }
        if (!matched) i++;
      }
    }
  }
  return out;
}
