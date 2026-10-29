// Procedural 3D hand: joint-angle poses → forward kinematics → perspective
// projection → depth-sorted primitives. Pure Dart (no Flutter imports) so the
// geometry can be unit-tested.
//
// Hand-local frame (signer's RIGHT hand, palm facing the viewer):
//   +x  toward the thumb side (viewer's right)
//   +y  from wrist toward fingertips
//   +z  out of the palm, toward the viewer — fingers flex toward +z
// World frame: origin near the signer's chin, +y up, +z toward the viewer.
// One unit ≈ 10 cm.

import 'dart:math' as math;

double _rad(double deg) => deg * math.pi / 180;
double _lerp(double a, double b, double t) => a + (b - a) * t;

class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);
  static const zero = Vec3(0, 0, 0);

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(dot(this));
  Vec3 get normalized {
    final l = length;
    return l < 1e-9 ? this : this * (1 / l);
  }

  Vec3 lerp(Vec3 o, double t) =>
      Vec3(_lerp(x, o.x, t), _lerp(y, o.y, t), _lerp(z, o.z, t));

  // Rotations about the axes through the origin (degrees).
  Vec3 rotX(double deg) {
    final c = math.cos(_rad(deg)), s = math.sin(_rad(deg));
    return Vec3(x, y * c - z * s, y * s + z * c);
  }

  Vec3 rotY(double deg) {
    final c = math.cos(_rad(deg)), s = math.sin(_rad(deg));
    return Vec3(x * c + z * s, y, -x * s + z * c);
  }

  Vec3 rotZ(double deg) {
    final c = math.cos(_rad(deg)), s = math.sin(_rad(deg));
    return Vec3(x * c - y * s, x * s + y * c, z);
  }
}

// ─── Pose ────────────────────────────────────────────────────────────────────

/// Flexion of the three finger joints plus sideways spread, in degrees.
/// [spread] > 0 swings the finger toward the thumb side.
class FingerPose {
  final double mcp, pip, dip, spread;
  const FingerPose(this.mcp, this.pip, this.dip, [this.spread = 0]);

  FingerPose withSpread(double s) => FingerPose(mcp, pip, dip, s);

  FingerPose lerp(FingerPose o, double t) => FingerPose(_lerp(mcp, o.mcp, t),
      _lerp(pip, o.pip, t), _lerp(dip, o.dip, t), _lerp(spread, o.spread, t));
}

/// Thumb: [yaw] swings it in the palm plane (+ = away from the fingers,
/// − = across the palm), [lift] raises it out of the palm toward the viewer,
/// [mcp]/[ip] curl it across the palm.
class ThumbPose {
  final double yaw, lift, mcp, ip;
  const ThumbPose(this.yaw, this.lift, [this.mcp = 0, this.ip = 0]);

  ThumbPose lerp(ThumbPose o, double t) => ThumbPose(_lerp(yaw, o.yaw, t),
      _lerp(lift, o.lift, t), _lerp(mcp, o.mcp, t), _lerp(ip, o.ip, t));
}

class HandPose {
  /// index, middle, ring, pinky
  final List<FingerPose> fingers;
  final ThumbPose thumb;

  /// Wrist orientation (degrees): applied roll (about z), then pitch
  /// (about x, + tips toward viewer), then yaw (about y, + palm turns to
  /// the viewer's right).
  final double yaw, pitch, roll;

  /// Wrist position in world space.
  final Vec3 position;

  const HandPose({
    required this.fingers,
    required this.thumb,
    this.yaw = 0,
    this.pitch = 0,
    this.roll = -6,
    this.position = HandPose.neutral,
  });

  /// Fingerspelling position: in front of the right shoulder.
  static const neutral = Vec3(-1.1, -2.1, 0.8);

  HandPose copyWith({
    List<FingerPose>? fingers,
    ThumbPose? thumb,
    double? yaw,
    double? pitch,
    double? roll,
    Vec3? position,
  }) =>
      HandPose(
        fingers: fingers ?? this.fingers,
        thumb: thumb ?? this.thumb,
        yaw: yaw ?? this.yaw,
        pitch: pitch ?? this.pitch,
        roll: roll ?? this.roll,
        position: position ?? this.position,
      );

  /// Same handshape, moved/rotated relative to this pose.
  HandPose moved({
    Vec3 by = Vec3.zero,
    double yaw = 0,
    double pitch = 0,
    double roll = 0,
  }) =>
      copyWith(
        position: position + by,
        yaw: this.yaw + yaw,
        pitch: this.pitch + pitch,
        roll: this.roll + roll,
      );

  /// 26 numbers for the 3D avatar (assets/avatar/avatar.js): per finger
  /// mcp, pip, dip, spread; thumb yaw, lift, mcp, ip; wrist yaw, pitch,
  /// roll; wrist position x, y, z.
  List<double> toArray() => [
        for (final f in fingers) ...[f.mcp, f.pip, f.dip, f.spread],
        thumb.yaw, thumb.lift, thumb.mcp, thumb.ip,
        yaw, pitch, roll,
        position.x, position.y, position.z,
      ];

  HandPose lerp(HandPose o, double t) => HandPose(
        fingers: [for (var i = 0; i < 4; i++) fingers[i].lerp(o.fingers[i], t)],
        thumb: thumb.lerp(o.thumb, t),
        yaw: _lerp(yaw, o.yaw, t),
        pitch: _lerp(pitch, o.pitch, t),
        roll: _lerp(roll, o.roll, t),
        position: position.lerp(o.position, t),
      );

  /// Re-aims the thumb so its tip meets the tip of finger [finger]
  /// (0 = index … 3 = pinky). Used for O, F, D and the numbers 6–9.
  HandPose thumbTouching(int finger) {
    final target = HandSkeleton.local(this).fingers[finger].last;
    ThumbPose best = thumb;
    double bestD = double.infinity;

    void search(double y0, double y1, double l0, double l1, double c0,
        double c1, double step) {
      for (var y = y0; y <= y1; y += step) {
        for (var l = l0; l <= l1; l += step) {
          for (var c = c0; c <= c1; c += step) {
            final t = ThumbPose(y, l, c, c);
            final d = (HandSkeleton.thumbChain(t).last - target).length;
            if (d < bestD) {
              bestD = d;
              best = t;
            }
          }
        }
      }
    }

    search(-80, 50, 0, 85, 0, 70, 5); // coarse
    search(best.yaw - 5, best.yaw + 5, best.lift - 5, best.lift + 5,
        math.max(0, best.mcp - 5), best.mcp + 5, 1); // refine
    return copyWith(thumb: best);
  }
}

// ─── Skeleton (forward kinematics) ────────────────────────────────────────────

class HandSkeleton {
  /// Wrist corners (left/right of the forearm), hand-local.
  final List<Vec3> wrist;

  /// Per finger: [mcp, pip, dip, tip].
  final List<List<Vec3>> fingers;

  /// [cmc, mcp, ip, tip]
  final List<Vec3> thumb;

  const HandSkeleton(this.wrist, this.fingers, this.thumb);

  static const fingerBase = [
    Vec3(0.33, 0.95, 0),
    Vec3(0.11, 1.0, 0),
    Vec3(-0.11, 0.96, 0),
    Vec3(-0.31, 0.86, 0),
  ];
  static const fingerLengths = [
    [0.45, 0.27, 0.20],
    [0.50, 0.30, 0.21],
    [0.47, 0.28, 0.20],
    [0.37, 0.21, 0.18],
  ];
  static const fingerRadius = [
    [0.095, 0.085, 0.078],
    [0.098, 0.088, 0.080],
    [0.092, 0.083, 0.076],
    [0.080, 0.072, 0.066],
  ];
  static const thumbBase = Vec3(0.30, 0.22, 0.06);
  static const thumbLengths = [0.42, 0.32, 0.26];
  static const thumbRadius = [0.13, 0.11, 0.095];

  static List<Vec3> thumbChain(ThumbPose t) {
    final yaw = _rad(t.yaw), lift = _rad(t.lift);
    final d1 = Vec3(math.sin(yaw) * math.cos(lift),
        math.cos(yaw) * math.cos(lift), math.sin(lift));
    // Curling bends the thumb across the palm, in front of it.
    const across = Vec3(-0.75, 0.1, 0.65);
    final n = (across - d1 * across.dot(d1)).normalized;
    Vec3 dir(double deg) => d1 * math.cos(_rad(deg)) + n * math.sin(_rad(deg));

    const p0 = thumbBase;
    final p1 = p0 + d1 * thumbLengths[0];
    final p2 = p1 + dir(t.mcp) * thumbLengths[1];
    final p3 = p2 + dir(t.mcp + t.ip) * thumbLengths[2];
    return [p0, p1, p2, p3];
  }

  static List<Vec3> fingerChain(int i, FingerPose f) {
    final spread = _rad(f.spread);
    final base = Vec3(math.sin(spread), math.cos(spread), 0);
    const palmward = Vec3(0, 0, 1);
    Vec3 dir(double deg) =>
        base * math.cos(_rad(deg)) + palmward * math.sin(_rad(deg));

    final len = fingerLengths[i];
    final p0 = fingerBase[i];
    final p1 = p0 + dir(f.mcp) * len[0];
    final p2 = p1 + dir(f.mcp + f.pip) * len[1];
    final p3 = p2 + dir(f.mcp + f.pip + f.dip) * len[2];
    return [p0, p1, p2, p3];
  }

  /// Joints in the hand-local frame (no wrist transform).
  static HandSkeleton local(HandPose pose) => HandSkeleton(
        const [Vec3(0.30, 0, 0), Vec3(-0.28, 0, 0)],
        [for (var i = 0; i < 4; i++) fingerChain(i, pose.fingers[i])],
        thumbChain(pose.thumb),
      );

  HandSkeleton map(Vec3 Function(Vec3) f) => HandSkeleton(
        wrist.map(f).toList(),
        [for (final c in fingers) c.map(f).toList()],
        thumb.map(f).toList(),
      );

  /// Joints in world space.
  static HandSkeleton world(HandPose pose) => local(pose).map((p) =>
      p.rotZ(pose.roll).rotX(pose.pitch).rotY(pose.yaw) + pose.position);
}

// ─── Projection to 2D primitives ──────────────────────────────────────────────

enum PrimKind { palm, finger, thumb, arm }

class Prim2D {
  final PrimKind kind;

  /// Projected points (x, y) — 2 for a capsule, n for the palm polygon.
  final List<(double, double)> points;

  /// Capsule radius in pixels (palm: edge thickness).
  final double radius;

  /// Mean depth (world z after view rotation); larger = nearer the viewer.
  final double depth;

  /// For the palm: true when the palm side (not the back) faces the viewer.
  final bool palmFacing;

  const Prim2D(this.kind, this.points, this.radius, this.depth,
      {this.palmFacing = true});
}

class HandCamera {
  /// Screen size in pixels.
  final double width, height;

  /// Extra rotation the user applied by dragging, about the chest.
  final double viewYaw, viewPitch;

  const HandCamera(this.width, this.height,
      {this.viewYaw = 0, this.viewPitch = 0});

  static const _distance = 16.0;

  /// World window that must fit on screen: 5.8 × 5.8 units around the
  /// signing space (both hands, chin and chest; the top of the head may crop).
  double get scale => math.min(width / 5.8, height / 5.8);
  static const _cx = 0.0, _cy = -0.7; // world point at screen centre

  (double, double) project(Vec3 p) {
    final k = _distance / (_distance - p.z);
    return (
      width / 2 + (p.x - _cx) * k * scale,
      height / 2 - (p.y - _cy) * k * scale
    );
  }

  double projectRadius(double r, double z) =>
      r * scale * _distance / (_distance - z);
}

/// Projects both hands into 2D primitives, farthest first.
///
/// [left] is authored like a right hand placed on the mirrored side of the
/// body (e.g. x = −1.1 for "in front of the left shoulder") and is then
/// mirrored across the body's midline, so a symmetric two-handed sign can
/// use the same pose for both hands.
List<Prim2D> buildScenePrims(HandPose right, HandPose left, HandCamera cam) {
  Vec3 mirror(Vec3 p) => Vec3(-p.x, p.y, p.z);
  // The camera looks slightly down on the signing space so palm-down hands
  // (WALK, TRAIN, …) aren't seen edge-on; viewer drag adds to that, about
  // the chest.
  const pivot = Vec3(0, -1.6, 0.6);
  const elevation = 14.0;
  Vec3 view(Vec3 p) => (p - pivot)
          .rotY(cam.viewYaw)
          .rotX(cam.viewPitch + elevation) +
      pivot;

  final arms = <Prim2D>[];
  final parts = <Prim2D>[];
  for (final (pose, mirrored) in [(right, false), (left, true)]) {
    var skel = HandSkeleton.world(pose);

    // Palm normal (+z in the local frame); a mirror in x keeps its z.
    final normal = (skel.fingers[0][0] - skel.wrist[1])
        .cross(skel.fingers[3][0] - skel.wrist[0]);

    // Forearm: the wrist bends, so the arm only partly follows the hand.
    final wristMid = skel.wrist[0].lerp(skel.wrist[1], 0.5);
    final armDir = const Vec3(0, -1, 0)
        .rotZ(pose.roll * 0.45)
        .rotX(pose.pitch * 0.25)
        .rotY(pose.yaw * 0.3);
    var armStart = wristMid, armEnd = wristMid + armDir * 1.5;

    Vec3 toView(Vec3 p) => view(mirrored ? mirror(p) : p);
    skel = skel.map(toView);
    armStart = toView(armStart);
    armEnd = toView(armEnd);

    void capsule(PrimKind kind, Vec3 a, Vec3 b, double r) {
      final z = (a.z + b.z) / 2;
      parts.add(Prim2D(kind, [cam.project(a), cam.project(b)],
          cam.projectRadius(r, z), z));
    }

    // Palm: wrist corners + knuckles + thumb root.
    final palmPts = [
      skel.wrist[1],
      skel.wrist[0],
      skel.thumb[0],
      skel.fingers[0][0],
      skel.fingers[1][0],
      skel.fingers[2][0],
      skel.fingers[3][0],
    ];
    final palmDepth =
        palmPts.map((p) => p.z).reduce((a, b) => a + b) / palmPts.length;
    parts.add(Prim2D(
      PrimKind.palm,
      palmPts.map(cam.project).toList(),
      cam.projectRadius(0.11, palmDepth),
      palmDepth,
      palmFacing: normal.z > 0,
    ));
    for (var i = 0; i < 4; i++) {
      final c = skel.fingers[i];
      for (var s = 0; s < 3; s++) {
        capsule(
            PrimKind.finger, c[s], c[s + 1], HandSkeleton.fingerRadius[i][s]);
      }
    }
    for (var s = 0; s < 3; s++) {
      capsule(PrimKind.thumb, skel.thumb[s], skel.thumb[s + 1],
          HandSkeleton.thumbRadius[s]);
    }

    final armZ = (armStart.z + armEnd.z) / 2;
    arms.add(Prim2D(PrimKind.arm, [cam.project(armStart), cam.project(armEnd)],
        cam.projectRadius(0.24, armZ), armZ));
  }

  // Forearms hang behind the hands in every signing pose — draw them first.
  arms.sort((a, b) => a.depth.compareTo(b.depth));
  parts.sort((a, b) => a.depth.compareTo(b.depth));
  return [...arms, ...parts];
}
