// 3D signing avatar for Taiwan Bus Tracker.
//
// Loads a VRM humanoid (default: Seed-san by VirtualCast, Inc.) with
// three.js + three-vrm and plays sign timelines sent from Flutter. The
// timeline uses the same pose model as the app's 2D hand renderer
// (lib/widgets/sign_hand/hand_model.dart):
//   per hand: index/middle/ring/little × (mcp, pip, dip, spread),
//             thumb (yaw, lift, mcp, ip), wrist (yaw, pitch, roll),
//             wrist position (x, y, z) — 26 numbers, angles in degrees,
//             positions in ~10 cm units around the chin, +x = signer's left,
//             +y up, +z toward the viewer. The left hand is authored as a
//             right hand on the mirrored side.
// Arms are placed with two-bone IK; fingers copy the bone directions of the
// app's own finger kinematics.
//
// Bridge: Flutter → JS  window.avatar.play(json), .resetView()
//         JS → Flutter  AvatarBridge.postMessage(JSON) with
//                       {type: 'ready'|'error'|'sign'|'done', ...}

import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm';

const DEG = Math.PI / 180;
const params = new URLSearchParams(location.search);

function post(msg) {
  const s = JSON.stringify(msg);
  if (window.AvatarBridge) window.AvatarBridge.postMessage(s);
  else console.log('[avatar]', s);
}
window.addEventListener('error', (e) => post({ type: 'error', message: String(e.message) }));

// ─── App hand model (port of hand_model.dart) ─────────────────────────────

const FINGER_BASE = [
  [0.33, 0.95, 0], [0.11, 1.0, 0], [-0.11, 0.96, 0], [-0.31, 0.86, 0],
];
const FINGER_LEN = [
  [0.45, 0.27, 0.20], [0.50, 0.30, 0.21], [0.47, 0.28, 0.20], [0.37, 0.21, 0.18],
];
const THUMB_BASE = [0.30, 0.22, 0.06];
const THUMB_LEN = [0.42, 0.32, 0.26];

const v3 = (a) => new THREE.Vector3(a[0], a[1], a[2]);

/** Finger joint directions (3 unit vectors) in the hand-local frame. */
function fingerDirs(mcp, pip, dip, spread) {
  const s = spread * DEG;
  const base = new THREE.Vector3(Math.sin(s), Math.cos(s), 0);
  const dir = (deg) => base.clone().multiplyScalar(Math.cos(deg * DEG))
    .add(new THREE.Vector3(0, 0, Math.sin(deg * DEG)));
  return [dir(mcp), dir(mcp + pip), dir(mcp + pip + dip)];
}

function thumbDirs(yaw, lift, mcp, ip) {
  const y = yaw * DEG, l = lift * DEG;
  const d1 = new THREE.Vector3(Math.sin(y) * Math.cos(l), Math.cos(y) * Math.cos(l), Math.sin(l));
  const across = new THREE.Vector3(-0.75, 0.1, 0.65);
  const n = across.clone().sub(d1.clone().multiplyScalar(across.dot(d1))).normalize();
  const dir = (deg) => d1.clone().multiplyScalar(Math.cos(deg * DEG)).add(n.clone().multiplyScalar(Math.sin(deg * DEG)));
  return [d1, dir(mcp), dir(mcp + ip)];
}

/** Wrist rotation as a matrix: roll (z), then pitch (x), then yaw (y). */
function wristMatrix(yaw, pitch, roll) {
  const e = new THREE.Euler(pitch * DEG, yaw * DEG, roll * DEG, 'YXZ');
  return new THREE.Matrix4().makeRotationFromEuler(e);
}

// ─── Scene ─────────────────────────────────────────────────────────────────

const bg = new THREE.Color(params.get('bg') || '#0E1116');
const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: !!params.get('test') });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.setClearColor(bg);
renderer.outputColorSpace = THREE.SRGBColorSpace;
document.body.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(28, 1, 0.05, 20);
scene.add(new THREE.HemisphereLight(0xffffff, 0x445566, 1.6));
const key = new THREE.DirectionalLight(0xffffff, 1.8);
key.position.set(0.6, 1.5, 2.0);
scene.add(key);

// Soft floor-less backdrop glow behind the signer.
const glow = new THREE.Mesh(
  new THREE.CircleGeometry(0.75, 48),
  new THREE.MeshBasicMaterial({ color: 0x1fd1a5, transparent: true, opacity: 0.07 }));
scene.add(glow);

function resize() {
  const w = window.innerWidth, h = window.innerHeight;
  renderer.setSize(w, h, false);
  renderer.domElement.style.width = w + 'px';
  renderer.domElement.style.height = h + 'px';
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  frameCamera();
}
window.addEventListener('resize', resize);

// ─── Avatar rig ────────────────────────────────────────────────────────────

let vrm = null;
const rig = {}; // per side: bones, rest data
let anchor = new THREE.Vector3(); // world point for app-origin (chin)
let unit = 0.1; // metres per app unit (x, z)
let unitY = 0.1; // metres per app unit (y)
let viewYaw = 0, viewPitch = 0;

const FINGERS = ['Index', 'Middle', 'Ring', 'Little'];
const SEGS = ['Proximal', 'Intermediate', 'Distal'];
const THUMB = ['ThumbMetacarpal', 'ThumbProximal', 'ThumbDistal'];

function node(name) {
  return vrm.humanoid.getNormalizedBoneNode(name);
}
function wpos(n) {
  return n.getWorldPosition(new THREE.Vector3());
}

function setupSide(side) {
  const S = side === 'right' ? 'right' : 'left';
  const b = {
    upper: node(S + 'UpperArm'),
    lower: node(S + 'LowerArm'),
    hand: node(S + 'Hand'),
  };
  const pU = wpos(b.upper), pL = wpos(b.lower), pH = wpos(b.hand);
  const r = {
    side, ...b,
    lenA: pU.distanceTo(pL), lenB: pL.distanceTo(pH),
    restUpper: pL.clone().sub(pU).normalize(),
    restLower: pH.clone().sub(pL).normalize(),
    fingers: [], thumb: null,
  };
  const chain = (names) => {
    const nodes = names.map((n) => node(S + n));
    const pos = nodes.map(wpos);
    const dirs = [];
    for (let i = 0; i < nodes.length; i++) {
      const to = i + 1 < nodes.length ? pos[i + 1]
        : pos[i].clone().add(pos[i].clone().sub(pos[i - 1]).multiplyScalar(0.8));
      dirs.push(to.clone().sub(pos[i]).normalize());
    }
    return { nodes, rest: dirs };
  };
  for (const f of FINGERS) r.fingers.push(chain(SEGS.map((s) => f + s)));
  r.thumb = chain(THUMB);

  // Hand rest frame in the app's convention: x = thumb side, y = fingers,
  // z = palm normal (left hand: mirrored, so a left-handed frame).
  const y = wpos(r.fingers[1].nodes[0]).sub(pH).normalize();
  const across = wpos(r.fingers[0].nodes[0]).sub(wpos(r.fingers[3].nodes[0]));
  const x = across.sub(y.clone().multiplyScalar(across.dot(y))).normalize();
  const z = new THREE.Vector3().crossVectors(x, y);
  if (side === 'left') z.negate();
  r.restFrame = new THREE.Matrix4().makeBasis(x, y, z);
  rig[side] = r;
}

function frameCamera() {
  if (!vrm) return;
  const chest = wpos(node('upperChest') || node('chest'));
  const head = wpos(node('head'));
  const target = new THREE.Vector3(0, (chest.y + head.y) / 2 - 0.05, chest.z);
  // Fit roughly head-top to waist (~0.75 m tall), wider on landscape.
  const span = 0.42;
  const fov = camera.fov * DEG / 2;
  let dist = span / Math.tan(fov);
  if (camera.aspect < 0.75) dist /= camera.aspect / 0.75; // keep both hands in on narrow screens
  camera.position.set(
    target.x + Math.sin(viewYaw * DEG) * dist * Math.cos(viewPitch * DEG),
    target.y + Math.sin(viewPitch * DEG) * dist + 0.05,
    target.z + Math.cos(viewYaw * DEG) * dist * Math.cos(viewPitch * DEG));
  camera.lookAt(target);
  glow.position.set(target.x, target.y, target.z - 0.4);
  glow.lookAt(camera.position);
}

async function load() {
  const loader = new GLTFLoader();
  loader.register((p) => new VRMLoaderPlugin(p));
  const gltf = await loader.loadAsync(params.get('model') || 'Seed-san.vrm');
  vrm = gltf.userData.vrm;
  VRMUtils.removeUnnecessaryVertices(gltf.scene);
  // Named combineSkeletons in newer three-vrm releases.
  (VRMUtils.combineSkeletons || VRMUtils.removeUnnecessaryJoints).call(VRMUtils, gltf.scene);
  VRMUtils.rotateVRM0(vrm);
  scene.add(vrm.scene);
  vrm.scene.traverse((o) => { o.frustumCulled = false; });
  // Seed-san wears a robot-arm backpack; hide it so only the signer's own
  // arms move in view (the model's licence allows modification).
  const HIDE = /^(robo_arm|backpack_|robo_face)/;
  vrm.scene.traverse((o) => {
    if (!o.isMesh) return;
    const mats = Array.isArray(o.material) ? o.material : [o.material];
    if (HIDE.test(o.name) || HIDE.test(o.parent?.name || '') || mats.every((m) => HIDE.test(m?.name || ''))) {
      o.visible = false;
    }
  });

  vrm.update(0);
  vrm.scene.updateMatrixWorld(true);
  setupSide('right');
  setupSide('left');

  // App origin = just in front of the chin; app units scaled so the app's
  // shoulder width (4.6 units) matches the avatar's.
  // Horizontal scale from shoulder width (4.6 app units); vertical scale
  // from the chin-to-shoulder drop (1.0 app unit), so stylised proportions
  // (narrow shoulders, long neck) still put chest signs at the chest.
  const sR = wpos(node('rightUpperArm')), sL = wpos(node('leftUpperArm'));
  unit = sR.distanceTo(sL) / 4.6;
  const head = wpos(node('head')), neck = wpos(node('neck'));
  anchor.set(0, head.y - (head.y - neck.y) * 0.1, head.z + unit * 1.2);
  unitY = Math.max(unit, (anchor.y - (sR.y + sL.y) / 2) / 1.0);
  console.log('[avatar] scale', JSON.stringify({ unit, unitY, anchor, shoulderY: sR.y, head: head.y, neck: neck.y }));

  resize();
  post({ type: 'ready' });

  // Development hook: ?test=STOP freezes on the end pose of t_STOP.json.
  const test = params.get('test');
  if (test) {
    const tl = await (await fetch('t_' + test + '.json')).json();
    const ms = params.get('ms') ? Number(params.get('ms')) : tl.spans[0][1] - 10;
    window.avatar.freeze(tl, ms);
  }
}

// ─── Posing ────────────────────────────────────────────────────────────────

const _q = new THREE.Quaternion();
function worldQuat(o) { return o.getWorldQuaternion(new THREE.Quaternion()); }

/** Sets [o]'s local rotation so its world rotation becomes [qw]. */
function setWorldQuat(o, qw) {
  const parentQ = worldQuat(o.parent);
  o.quaternion.copy(parentQ.invert().multiply(qw));
  o.updateMatrixWorld(true);
}

const MIRROR = new THREE.Matrix4().makeScale(-1, 1, 1);

function poseSide(side, a) {
  const r = rig[side];
  const left = side === 'left';
  // ── Target wrist position & hand frame in avatar space ──
  let p = new THREE.Vector3(a[23], a[24], a[25]);
  const W = wristMatrix(a[20], a[21], a[22]);
  const frame = left ? MIRROR.clone().multiply(W) : W; // columns: x, y, z
  if (left) p.x = -p.x;
  // The chest is in front of the chin: push hands forward the lower they
  // are, so chest-level signs stay clear of the body.
  const forward = THREE.MathUtils.clamp((-p.y - 0.8) * 0.7, 0, 1.8);
  const target = anchor.clone().add(new THREE.Vector3(
    p.x * unit, p.y * unitY, (p.z + forward) * unit));

  // ── Two-bone IK for the arm ──
  const S = wpos(r.upper);
  const toT = target.clone().sub(S);
  const reach = r.lenA + r.lenB;
  let d = THREE.MathUtils.clamp(toT.length(), Math.abs(r.lenA - r.lenB) + 1e-3, reach * 0.999);
  const dir = toT.normalize();
  const T = S.clone().add(dir.clone().multiplyScalar(d));
  const along = (r.lenA * r.lenA - r.lenB * r.lenB + d * d) / (2 * d);
  const h = Math.sqrt(Math.max(r.lenA * r.lenA - along * along, 0));
  // Elbows hang down, a little out and back.
  const pole = new THREE.Vector3(left ? 0.45 : -0.45, -1, -0.35);
  pole.sub(dir.clone().multiplyScalar(pole.dot(dir))).normalize();
  const E = S.clone().add(dir.clone().multiplyScalar(along)).add(pole.multiplyScalar(h));

  const qUpper = new THREE.Quaternion().setFromUnitVectors(r.restUpper, E.clone().sub(S).normalize());
  setWorldQuat(r.upper, qUpper);
  const qLower = new THREE.Quaternion().setFromUnitVectors(r.restLower, T.clone().sub(E).normalize());
  setWorldQuat(r.lower, qLower);

  // ── Hand: rotation taking the rest frame to the target frame ──
  const rot = frame.clone().multiply(r.restFrame.clone().transpose());
  const qHand = new THREE.Quaternion().setFromRotationMatrix(rot);
  setWorldQuat(r.hand, qHand);

  // Share half the wrist twist with the forearm so the skin doesn't wrap.
  const axis = r.restLower.clone(); // forearm axis in the forearm's rest frame
  const lq = r.hand.quaternion;
  const proj = axis.clone().multiplyScalar(axis.dot(new THREE.Vector3(lq.x, lq.y, lq.z)));
  const twist = new THREE.Quaternion(proj.x, proj.y, proj.z, lq.w).normalize();
  const half = new THREE.Quaternion().slerp(twist, 0.5);
  r.lower.quaternion.multiply(half);
  r.hand.quaternion.premultiply(half.clone().invert());
  r.lower.updateMatrixWorld(true);

  // ── Fingers: match the app's joint directions, in the hand rest frame ──
  const toRest = (v) => v.clone().applyMatrix4(r.restFrame);
  const chainTo = (chain, dirs) => {
    let parent = new THREE.Quaternion();
    for (let i = 0; i < 3; i++) {
      const g = new THREE.Quaternion().setFromUnitVectors(chain.rest[i], toRest(dirs[i]).normalize());
      chain.nodes[i].quaternion.copy(parent.clone().invert().multiply(g));
      parent = g;
    }
  };
  for (let f = 0; f < 4; f++) {
    chainTo(r.fingers[f], fingerDirs(a[f * 4], a[f * 4 + 1], a[f * 4 + 2], a[f * 4 + 3]));
  }
  chainTo(r.thumb, thumbDirs(a[16], a[17], a[18], a[19]));
}

// ─── Timeline playback ─────────────────────────────────────────────────────

let timeline = null; // {keys:[{at, r:[], l:[]}], spans:[[s,e,id]], total}
let speed = 1;
let startAt = 0;
let lastSign = -2;
let doneSent = false;
let frozenAt = null;

const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const lerpArr = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);

function sample(ms) {
  const k = timeline.keys;
  for (let i = 1; i < k.length; i++) {
    if (ms <= k[i].at) {
      const span = k[i].at - k[i - 1].at;
      const t = span === 0 ? 1 : ease(Math.min(Math.max((ms - k[i - 1].at) / span, 0), 1));
      return { r: lerpArr(k[i - 1].r, k[i].r, t), l: lerpArr(k[i - 1].l, k[i].l, t) };
    }
  }
  return { r: k[k.length - 1].r, l: k[k.length - 1].l };
}

// Facial expression that goes with a sign (non-manual markers).
const SIGN_FACE = {
  WELCOME: ['happy', 1.0], HELLO: ['happy', 0.8], THANK_YOU: ['happy', 0.9], PLEASE: ['happy', 0.5],
  YES: ['happy', 0.4], SORRY: ['sad', 0.7], NO: ['angry', 0.25],
  WHERE: ['surprised', 0.5], HELP: ['surprised', 0.25],
};
const face = { happy: 0, sad: 0, angry: 0, surprised: 0 };

function updateFace(dt, signId, now) {
  const want = SIGN_FACE[signId] || null;
  for (const k of Object.keys(face)) {
    const target = want && want[0] === k ? want[1] : 0;
    face[k] += (target - face[k]) * Math.min(1, dt * 6);
    vrm.expressionManager?.setValue(k, face[k]);
  }
  // Natural blinking every few seconds.
  const phase = (now / 1000) % 4.2;
  vrm.expressionManager?.setValue('blink', phase < 0.12 ? Math.sin(phase / 0.12 * Math.PI) : 0);
}

window.avatar = {
  play(json) {
    timeline = typeof json === 'string' ? JSON.parse(json) : json;
    speed = timeline.speed || 1;
    startAt = performance.now();
    lastSign = -2;
    doneSent = false;
    frozenAt = null;
  },
  /** Test hook: show the pose at a fixed time. */
  freeze(json, ms) { this.play(json); frozenAt = ms; },
  resetView() { viewYaw = 0; viewPitch = 0; frameCamera(); },
};

// Drag to turn the camera around the signer; double-tap resets.
let drag = null;
renderer.domElement.addEventListener('pointerdown', (e) => { drag = { x: e.clientX, y: e.clientY }; });
window.addEventListener('pointerup', () => { drag = null; });
window.addEventListener('pointermove', (e) => {
  if (!drag) return;
  viewYaw = THREE.MathUtils.clamp(viewYaw - (e.clientX - drag.x) * 0.4, -80, 80);
  viewPitch = THREE.MathUtils.clamp(viewPitch + (e.clientY - drag.y) * 0.3, -20, 40);
  drag = { x: e.clientX, y: e.clientY };
  frameCamera();
});
renderer.domElement.addEventListener('dblclick', () => window.avatar.resetView());

const clock = new THREE.Clock();
function frame(now) {
  requestAnimationFrame(frame);
  const dt = Math.min(clock.getDelta(), 0.1);
  if (!vrm) return;
  let signId = null;
  if (timeline) {
    const ms = frozenAt ?? (now - startAt) * speed;
    const pose = sample(ms);
    poseSide('right', pose.r);
    poseSide('left', pose.l);
    let idx = -1;
    timeline.spans.forEach((s, i) => { if (ms >= s[0] && ms < s[1]) { idx = i; signId = s[2]; } });
    if (idx !== lastSign) {
      lastSign = idx;
      post({ type: 'sign', index: idx < 0 ? null : idx });
    }
    if (frozenAt === null && ms > timeline.total && !doneSent) {
      doneSent = true;
      post({ type: 'done' });
    }
  }
  // Gentle breathing.
  const chest = node('chest');
  if (chest) chest.rotation.x = Math.sin(now / 1400) * 0.015;
  updateFace(dt, signId, now);
  vrm.update(dt);
  renderer.render(scene, camera);
}

load().catch((e) => post({ type: 'error', message: String(e && e.message || e) }));
requestAnimationFrame(frame);
