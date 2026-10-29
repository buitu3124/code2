// Animated 3D hands that play a sequence of signs. Drag to rotate the view,
// double-tap to reset it.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../design/tokens.dart';
import 'hand_model.dart';
import 'sign_vocabulary.dart';

/// Both hands at one moment.
typedef HandPair = ({HandPose right, HandPose left});

/// Flattened keyframes for a list of signs.
class SignTimeline {
  final List<({HandPose right, HandPose left, int at})> _keys = [];

  /// Per sign: (start, end) in ms, for captions.
  final List<(int, int)> spans = [];
  late final int totalMs;

  SignTimeline(List<String> signIds) {
    var t = 0;
    _keys.add((right: restPose, left: leftRest, at: 0));
    for (final id in signIds) {
      final def = signVocabulary[id];
      if (def == null) continue;
      final start = t;
      for (var k = 0; k < def.keys.length; k++) {
        final key = def.keys[k];
        // Moving into a new sign takes longer than moving within one.
        t += k == 0 ? 340 : key.moveMs;
        _keys.add((right: key.pose, left: key.left ?? leftRest, at: t));
      }
      t += def.holdMs;
      final last = def.keys.last;
      _keys.add((right: last.pose, left: last.left ?? leftRest, at: t));
      spans.add((start, t));
    }
    t += 420;
    _keys.add((right: restPose, left: leftRest, at: t));
    totalMs = t;
  }

  HandPair poseAt(double ms) {
    for (var i = 1; i < _keys.length; i++) {
      final a = _keys[i - 1], b = _keys[i];
      if (ms <= b.at) {
        final span = b.at - a.at;
        if (span == 0) return (right: b.right, left: b.left);
        final t = Curves.easeInOut.transform(((ms - a.at) / span).clamp(0, 1));
        return (right: a.right.lerp(b.right, t), left: a.left.lerp(b.left, t));
      }
    }
    return (right: _keys.last.right, left: _keys.last.left);
  }

  /// The timeline for the 3D avatar: keyframes with both hands' poses and
  /// the span of each sign (start, end, id) in ms.
  Map<String, dynamic> toJson(List<String> signIds, {double speed = 1}) {
    final ids = signIds.where(signVocabulary.containsKey).toList();
    return {
      'total': totalMs,
      'speed': speed,
      'keys': [
        for (final k in _keys)
          {'at': k.at, 'r': k.right.toArray(), 'l': k.left.toArray()},
      ],
      'spans': [
        for (var i = 0; i < spans.length; i++)
          [spans[i].$1, spans[i].$2, ids[i]],
      ],
    };
  }

  int? signIndexAt(double ms) {
    for (var i = 0; i < spans.length; i++) {
      if (ms >= spans[i].$1 && ms < spans[i].$2) return i;
    }
    return null;
  }
}

class SignHandView extends StatefulWidget {
  /// Sign ids from [signVocabulary]; unknown ids are skipped.
  final List<String> signs;

  /// Change this to replay the same sequence.
  final int playToken;

  /// 1.0 = normal; lower is slower.
  final double speed;

  /// Index into [signs] currently being signed, null between signs.
  final ValueChanged<int?>? onSignIndex;

  const SignHandView({
    super.key,
    required this.signs,
    this.playToken = 0,
    this.speed = 1.0,
    this.onSignIndex,
  });

  @override
  State<SignHandView> createState() => _SignHandViewState();
}

class _SignHandViewState extends State<SignHandView>
    with SingleTickerProviderStateMixin {
  late SignTimeline _timeline;
  late final AnimationController _ctrl;
  List<String> _validSigns = const [];
  int? _lastIndex;
  double _viewYaw = 0, _viewPitch = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this)..addListener(_onTick);
    _start();
  }

  @override
  void didUpdateWidget(SignHandView old) {
    super.didUpdateWidget(old);
    if (old.playToken != widget.playToken ||
        old.speed != widget.speed ||
        !_listEquals(old.signs, widget.signs)) {
      _start();
    }
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _start() {
    _validSigns =
        widget.signs.where(signVocabulary.containsKey).toList(growable: false);
    _timeline = SignTimeline(_validSigns);
    _ctrl.duration = Duration(
        milliseconds: (_timeline.totalMs / widget.speed.clamp(0.2, 3)).round());
    _ctrl.forward(from: 0);
  }

  void _onTick() {
    final idx = _timeline.signIndexAt(_ctrl.value * _timeline.totalMs);
    if (idx != _lastIndex) {
      _lastIndex = idx;
      // Map back to the caller's index (unknown ids were skipped).
      int? original;
      if (idx != null) {
        var seen = -1;
        for (var i = 0; i < widget.signs.length; i++) {
          if (signVocabulary.containsKey(widget.signs[i])) seen++;
          if (seen == idx) {
            original = i;
            break;
          }
        }
      }
      // Ticks can fire synchronously from didUpdateWidget (mid-build), so
      // report after the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSignIndex?.call(original);
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (d) => setState(() {
        _viewYaw = (_viewYaw + d.delta.dx * 0.5) % 360;
        _viewPitch = (_viewPitch - d.delta.dy * 0.5).clamp(-80.0, 80.0);
      }),
      onDoubleTap: () => setState(() => _viewYaw = _viewPitch = 0),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: HandPosePainter(
            hands: _timeline.poseAt(_ctrl.value * _timeline.totalMs),
            viewYaw: _viewYaw,
            viewPitch: _viewPitch,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class HandPosePainter extends CustomPainter {
  final HandPair hands;
  final double viewYaw, viewPitch;

  HandPosePainter(
      {required this.hands, required this.viewYaw, required this.viewPitch});

  static const _skinLight = Color(0xFFF3CDAE);
  static const _skin = Color(0xFFDDA27E);
  static const _skinBack = Color(0xFFC88A66);
  static const _skinDark = Color(0xFFA86E4E);
  static const _outline = Color(0xFF5E3B2B);

  Offset _o((double, double) p) => Offset(p.$1, p.$2);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final cam = HandCamera(size.width, size.height,
        viewYaw: viewYaw, viewPitch: viewPitch);
    _paintBody(canvas, cam);

    final prims = buildScenePrims(hands.right, hands.left, cam);
    if (prims.isEmpty) return;
    final depths = prims.map((p) => p.depth);
    final minZ = depths.reduce(math.min), maxZ = depths.reduce(math.max);

    for (final p in prims) {
      // Nearer parts are lighter.
      final t = maxZ - minZ < 1e-6 ? 1.0 : (p.depth - minZ) / (maxZ - minZ);
      final outline = Paint()
        ..color = _outline
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;

      switch (p.kind) {
        case PrimKind.palm:
          final path = Path()..addPolygon(p.points.map(_o).toList(), true);
          final color = Color.lerp(
              p.palmFacing ? _skinBack : _skinDark,
              p.palmFacing ? _skinLight : _skin,
              0.35 + 0.4 * t)!;
          canvas.drawPath(path, outline..strokeWidth = p.radius * 2 + 2.5);
          canvas.drawPath(
              path,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = p.radius * 2
                ..strokeJoin = StrokeJoin.round);
          canvas.drawPath(path, Paint()..color = color);
        case PrimKind.finger:
        case PrimKind.thumb:
        case PrimKind.arm:
          final a = _o(p.points[0]), b = _o(p.points[1]);
          final base = p.kind == PrimKind.arm
              ? Color.lerp(_skinDark, _skinBack, t)!
              : Color.lerp(_skinBack, _skinLight, 0.25 + 0.75 * t)!;
          canvas.drawLine(a, b, outline..strokeWidth = p.radius * 2 + 2.5);
          canvas.drawLine(
              a,
              b,
              Paint()
                ..color = base
                ..strokeWidth = p.radius * 2
                ..strokeCap = StrokeCap.round);
          // Soft highlight along the top edge for a rounded look.
          if (p.kind != PrimKind.arm) {
            final dir = b - a;
            final len = dir.distance;
            if (len > 1) {
              final n = Offset(-dir.dy, dir.dx) / len * (p.radius * 0.35);
              canvas.drawLine(
                  a + n,
                  b + n,
                  Paint()
                    ..color = Colors.white.withValues(alpha: 0.18)
                    ..strokeWidth = p.radius * 0.6
                    ..strokeCap = StrokeCap.round);
            }
          }
      }
    }
  }

  /// Faint head and shoulders so locations like "at the chin" make sense.
  void _paintBody(Canvas canvas, HandCamera cam) {
    final fill = Paint()..color = AppPalette.surfaceRaised;
    final edge = Paint()
      ..color = AppPalette.outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    const z = -1.6;
    final torso = Path()
      ..addPolygon([
        for (final (x, y) in const [
          (-0.45, 0.0), (0.45, 0.0), (0.5, -0.6), (2.3, -1.0), (2.7, -1.8),
          (2.7, -4.6), (-2.7, -4.6), (-2.7, -1.8), (-2.3, -1.0), (-0.5, -0.6),
        ])
          _o(cam.project(Vec3(x, y, z))),
      ], true);
    canvas.drawPath(torso, fill);
    canvas.drawPath(torso, edge);

    final c = _o(cam.project(const Vec3(0, 1.25, z)));
    final rx = cam.projectRadius(0.82, z), ry = cam.projectRadius(1.08, z);
    final head = Rect.fromCenter(center: c, width: rx * 2, height: ry * 2);
    canvas.drawOval(head, fill);
    canvas.drawOval(head, edge);

    // Mouth line as the chin/mouth landmark.
    final m = _o(cam.project(const Vec3(0, 0.62, z)));
    canvas.drawLine(m - Offset(rx * 0.25, 0), m + Offset(rx * 0.25, 0),
        edge..strokeWidth = 2);
    // Eyes
    for (final ex in const [-0.3, 0.3]) {
      canvas.drawCircle(_o(cam.project(Vec3(ex, 1.35, z))),
          math.max(2, rx * 0.07), Paint()..color = AppPalette.outline);
    }
  }

  @override
  bool shouldRepaint(HandPosePainter old) =>
      old.hands != hands ||
      old.viewYaw != viewYaw ||
      old.viewPitch != viewPitch;
}
