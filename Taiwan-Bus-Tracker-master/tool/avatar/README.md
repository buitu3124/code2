# 3D signing avatar

Source of `assets/avatar/avatar.js`, the WebView page that renders the 3D
signer in the sign-language assistant (`lib/widgets/sign_hand/sign_avatar_view.dart`).

- `src/avatar.js` — loads the VRM model with three.js + three-vrm, places the
  arms with two-bone IK and copies the finger poses of the app's own hand
  model (`lib/widgets/sign_hand/hand_model.dart`). Signs come from Flutter as a
  timeline (`SignTimeline.toJson`).
- `npm install && npm run build` — rebuilds `assets/avatar/avatar.js`.

## Model

`assets/avatar/Seed-san.vrm` — **Seed-san model by VirtualCast, Inc.**,
[VRM Public License 1.0](https://vrm.dev/licenses/1.0/): commercial use,
redistribution and modification allowed; **credit required** (shown in the
app under the avatar). Its robot-arm backpack is hidden at load time.

Any VRM 1.0 / 0.x humanoid with finger bones works: replace the file (or pass
`?model=other.vrm`) and update the credit line in `sign_avatar_view.dart`.

## Checking poses without a phone

Dump timelines with a throwaway Flutter test (`SignTimeline([id]).toJson([id])`
written to `assets/avatar/t_<ID>.json`), then `npm run serve` and open
`http://127.0.0.1:8765/index.html?test=STOP` (freezes on the end pose; add
`&ms=1200` for another moment). `node sheet.mjs out.png STOP WALK …` renders a
contact sheet with headless Chrome. Delete the `t_*.json` files afterwards.
