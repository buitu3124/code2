// Sign-language assistant: a conversation answered by two animated 3D hands,
// for people who communicate in sign language or can't read the app's text.
//
// Ways in, from least to most reading required:
//  • picture tiles of popular places → bus directions from GPS + live data
//    (works without AI)
//  • common-word signs with emoji labels (offline phrasebook)
//  • free text → Claude, which can call plan_trip for directions to any
//    place ("I want to go to Nova Taichung")
// Every answer is a list of steps (walk → take bus N → ride K stops → get
// off → walk) signed one after another, with pictograms, one big line per
// step, and a card to show the bus driver.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import '../design/tokens.dart';
import '../providers/bus_providers.dart';
import '../services/assistant_context.dart';
import '../services/assistant_tools.dart';
import '../services/claude_api.dart';
import '../services/place_search.dart';
import '../services/sign_answer.dart';
import '../services/trip_planner.dart';
import '../services/voice_service.dart';
import '../utils/app_strings.dart';
import '../widgets/sign_hand/sign_avatar_view.dart';
import '../widgets/sign_hand/sign_hand_view.dart';
import '../widgets/sign_hand/sign_vocabulary.dart';

/// Pictograms an answer step can use.
const pictogramIcons = <String, IconData>{
  'bus': Icons.directions_bus_rounded,
  'stop': Icons.place_rounded,
  'walk': Icons.directions_walk_rounded,
  'flag': Icons.flag_rounded,
  'transfer': Icons.transfer_within_a_station_rounded,
  'clock': Icons.schedule_rounded,
  'wait': Icons.hourglass_bottom_rounded,
  'left': Icons.turn_left_rounded,
  'right': Icons.turn_right_rounded,
  'straight': Icons.straight_rounded,
  'map': Icons.map_rounded,
  'train': Icons.train_rounded,
  'hospital': Icons.local_hospital_rounded,
  'toilet': Icons.wc_rounded,
  'money': Icons.payments_rounded,
  'card': Icons.credit_card_rounded,
  'phone': Icons.phone_rounded,
  'help': Icons.support_rounded,
  'yes': Icons.check_circle_rounded,
  'no': Icons.cancel_rounded,
  'chat': Icons.chat_bubble_rounded,
};

const _wordEmoji = {
  'HELLO': '👋', 'THANK_YOU': '🙏', 'YES': '👍', 'NO': '👎', 'HELP': '🆘',
  'WHERE': '❓', 'WAIT': '✋', 'BUS': '🚌', 'STOP': '🚏', 'GET_ON': '⤴️',
  'GET_OFF': '⤵️', 'WALK': '🚶', 'TRAIN': '🚆', 'TOILET': '🚻', 'WATER': '💧',
  'PLEASE': '🙂', 'SORRY': '😔',
};

IconData _placeIcon(PlaceResult p) {
  final n = p.shortName;
  if (n.contains('高鐵') || n.contains('火車') || n.contains('車站')) {
    return Icons.train_rounded;
  }
  if (n.contains('機場')) return Icons.flight_rounded;
  if (n.contains('大學')) return Icons.school_rounded;
  if (n.contains('榮總') || n.contains('醫院')) {
    return Icons.local_hospital_rounded;
  }
  if (n.contains('百貨') || n.contains('三越') || n.contains('商圈')) {
    return Icons.shopping_bag_rounded;
  }
  if (n.contains('市政府')) return Icons.account_balance_rounded;
  if (n.contains('歌劇院')) return Icons.theater_comedy_rounded;
  if (n.contains('轉運站')) return Icons.directions_bus_rounded;
  return Icons.place_rounded;
}

String _systemPrompt(AppLanguage lang) {
  final language =
      lang == AppLanguage.zh ? 'Traditional Chinese (繁體中文)' : 'English';
  return '''
You are the sign-language assistant in a Taichung bus app. The passenger communicates in sign language and may not be able to read. Every answer is performed by animated hands, together with a pictogram and one big line per step; the short text is for anyone helping them.

Answer format:
- reply: one or two short, simple sentences in $language.
- steps: 1 to 6 steps, in order. For each step:
  - pictogram: the icon that shows the step.
  - big_text: only the key information (route number, minutes, stop name), or "".
  - text: one short sentence in $language.
  - signs: the step in signs from the allowed list. Use a word sign when one fits; sign numbers digit by digit (route 52 is "5", "2"); fingerspell other essential English words letter by letter. At most about 10 signs per step, no filler words.
  - card: "" unless the passenger should show something to the driver or staff; then a short polite message in Traditional Chinese followed by the same in English.

Directions: when the passenger wants to go somewhere, call plan_trip. It uses their GPS position and live bus data. Pass the destination names to try, best first: the passenger's own wording, and the place's official English and Traditional Chinese names if you know them. If the result has suggested_steps, use them as your steps — you may shorten the text, but keep the route numbers, stop names, signs and cards exactly. If the place can't be found or seems wrong, say so and ask which place they mean (sign WHERE).

Only state routes, stops and times that come from plan_trip or the live data in the passenger's message; never invent them. For emergencies the card says to call 119 (ambulance/fire) or 110 (police), with the phone or help pictogram.
''';
}

class _Turn {
  final String question;
  final IconData? questionIcon;
  final SignAnswer answer;
  const _Turn(this.question, this.answer, {this.questionIcon});
}

class SignAssistantScreen extends ConsumerStatefulWidget {
  const SignAssistantScreen({super.key});

  @override
  ConsumerState<SignAssistantScreen> createState() =>
      _SignAssistantScreenState();
}

class _SignAssistantScreenState extends ConsumerState<SignAssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _voice = VoiceService.instance;
  bool _listening = false;

  final List<_Turn> _turns = [];

  /// Raw Messages API history for the AI conversation (append-only).
  final List<Map<String, dynamic>> _apiMessages = [];

  // What the hands are playing.
  List<String> _signs = const ['WELCOME']; // both hands wave hello
  List<int>? _stepOfSign; // step index per sign, when playing a turn
  int? _playingTurn;
  int _playToken = 0;
  int? _current;
  bool _slow = false;
  // 3D human signer where supported; the 2D hands are the light option.
  bool _use3d = avatarSupported;

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _voice.stopListening();
    _voice.stopSpeaking();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  AppLanguage get _lang => ref.read(languageProvider);

  void _play(List<String> signs, {int? turn, List<int>? stepOfSign}) {
    setState(() {
      _signs = signs;
      _playingTurn = turn;
      _stepOfSign = stepOfSign;
      _playToken++;
      _current = null;
    });
  }

  void _playTurn(int i) {
    final a = _turns[i].answer;
    _play(a.allSigns, turn: i, stepOfSign: a.stepOfSign);
  }

  void _playStep(int turn, int step) {
    final s = _turns[turn].answer.steps[step];
    _play(s.signs,
        turn: turn, stepOfSign: List.filled(s.signs.length, step));
  }

  void _addTurn(_Turn t) {
    setState(() {
      _turns.add(t);
      _error = null;
    });
    _playTurn(_turns.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  // ── Picture tile: directions without AI ──────────────────────────────────
  Future<void> _goTo(PlaceResult place) async {
    if (_loading) return;
    final lang = _lang;
    final name = lang == AppLanguage.en && place.shortNameEn.isNotEmpty
        ? place.shortNameEn
        : place.shortName;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final origin = await AssistantContext.position();
      SignAnswer answer;
      if (origin == null) {
        answer = SignAnswer(
            reply: AppStrings.t(lang, 'signNeedLocation'),
            steps: [
              SignStep(
                pictogram: 'map',
                bigText: '',
                text: AppStrings.t(lang, 'signNeedLocation'),
                signs: const ['WHERE', 'I'],
              ),
            ]);
      } else {
        final plan = await TripPlanner.plan(origin: origin, destination: place);
        answer = plan == null
            ? SignAnswer(
                reply: AppStrings.t(lang, 'signNoRoute'),
                steps: [
                  SignStep(
                    pictogram: 'no',
                    bigText: name,
                    text: AppStrings.t(lang, 'signNoRoute'),
                    signs: const ['NO', 'BUS'],
                  ),
                ])
            : tripToAnswer(plan, lang);
      }
      if (!mounted) return;
      // Keep the AI conversation aware of this exchange.
      _apiMessages
        ..add({'role': 'user', 'content': 'Passenger: I want to go to $name'})
        ..add({'role': 'assistant', 'content': jsonEncode(answer.toJson())});
      _addTurn(_Turn(name, answer, questionIcon: _placeIcon(place)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Free text / quick question: Claude with the plan_trip tool ──────────
  Future<void> _ask(String question, {IconData? icon}) async {
    question = question.trim();
    if (question.isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    _input.clear();
    final lang = _lang;
    final rollback = _apiMessages.length;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final live = await AssistantContext.load();
      // Live data rides in the user turn so the system prompt stays fixed
      // for the whole conversation.
      _apiMessages.add({
        'role': 'user',
        'content': 'Live data:\n$live\n\nPassenger: $question',
      });
      final json = await ClaudeApi.structuredWithTools(
        system: _systemPrompt(lang),
        messages: _apiMessages,
        schema: signAnswerSchema(pictogramIcons.keys),
        tools: [planTripTool()],
        runTool: (name, input) => name == 'plan_trip'
            ? runPlanTrip(input, lang)
            : Future.value('Unknown tool $name'),
      );
      if (!mounted) return;
      _addTurn(_Turn(question, SignAnswer.fromJson(json), questionIcon: icon));
    } catch (e) {
      // Drop the unanswered exchange so the history stays valid.
      _apiMessages.removeRange(rollback, _apiMessages.length);
      if (mounted) {
        setState(() => _error = e.toString());
        _input.text = question;
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Offline: fingerspell typed text ──────────────────────────────────────
  void _signLocally(String text) {
    final signs = textToSigns(text);
    if (signs.isEmpty) return;
    FocusScope.of(context).unfocus();
    _input.clear();
    _addTurn(_Turn(
        text,
        SignAnswer(reply: '', steps: [
          SignStep(pictogram: 'chat', bigText: text, text: '', signs: signs),
        ])));
  }

  void _send() {
    final text = _input.text;
    if (ClaudeApi.isConfigured) {
      _ask(text);
    } else {
      _signLocally(text);
    }
  }

  void _newConversation() {
    setState(() {
      _turns.clear();
      _apiMessages.clear();
      _error = null;
    });
    _play(const ['WELCOME']);
  }

  Future<void> _speak(String text) => _voice.speak(text, _lang);

  // A hearing helper can speak the question; the hands then sign the answer.
  Future<void> _listen() async {
    if (_listening) {
      await _voice.stopListening();
      return;
    }
    setState(() {
      _listening = true;
      _error = null;
    });
    final text = await _voice.listen(
      lang: _lang,
      onPartial: (w) {
        if (mounted) _input.text = w;
      },
    );
    if (!mounted) return;
    setState(() => _listening = false);
    if (text == null) {
      setState(() => _error = _voice.unavailableMessage(_lang));
    } else if (text.isNotEmpty) {
      _input.text = text;
      _send();
    }
  }

  String _label(String id, AppLanguage lang) {
    final def = signVocabulary[id];
    if (def == null) return id;
    return lang == AppLanguage.zh ? def.zh : def.en;
  }

  int? get _currentStep => _current == null || _stepOfSign == null
      ? null
      : _stepOfSign![_current!];

  // ── Sheets ───────────────────────────────────────────────────────────────
  void _showPlaces(AppLanguage lang) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppPalette.surface,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          // Lift the sheet above the keyboard while typing a place.
          padding: EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg,
              AppSpace.lg + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(AppStrings.t(lang, 'signWhereTo'), style: AppText.title),
              const SizedBox(height: AppSpace.md),
              _PlaceSearch(
                lang: lang,
                onPick: (p) {
                  Navigator.pop(ctx);
                  _goTo(p);
                },
              ),
              const SizedBox(height: AppSpace.md),
              Flexible(
                child: SingleChildScrollView(
                  child: _PlaceGrid(
                    lang: lang,
                    onTap: (p) {
                      Navigator.pop(ctx);
                      _goTo(p);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showWords(AppLanguage lang) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppPalette.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(AppStrings.t(lang, 'signQuickWords'), style: AppText.title),
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  for (final id in quickWordSigns)
                    ActionChip(
                      avatar: Text(_wordEmoji[id] ?? '',
                          style: const TextStyle(fontSize: 18)),
                      label: Text(_label(id, lang)),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _play([id]);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCard(String card) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.white,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.black, size: 32),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Text(card,
                          style: const TextStyle(
                              fontSize: 30,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: Colors.black)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final lang = ref.watch(languageProvider);
    final configured = ClaudeApi.isConfigured;

    return Scaffold(
      backgroundColor: AppPalette.canvas,
      appBar: AppBar(
        title: Text(AppStrings.t(lang, 'assistantSignTitle')),
        actions: [
          if (avatarSupported)
            IconButton(
              tooltip: AppStrings.t(lang, _use3d ? 'signUse2d' : 'signUse3d'),
              icon: Icon(_use3d
                  ? Icons.back_hand_outlined
                  : Icons.accessibility_new_rounded),
              onPressed: () => setState(() {
                _use3d = !_use3d;
                _playToken++;
              }),
            ),
          IconButton(
            tooltip: AppStrings.t(lang, 'signSlow'),
            isSelected: _slow,
            icon: const Icon(Icons.slow_motion_video_rounded),
            selectedIcon: const Icon(Icons.slow_motion_video_rounded,
                color: AppPalette.accent),
            onPressed: () => setState(() => _slow = !_slow),
          ),
          IconButton(
            tooltip: AppStrings.t(lang, 'signReplay'),
            icon: const Icon(Icons.replay_rounded),
            onPressed: () => setState(() => _playToken++),
          ),
          if (_turns.isNotEmpty)
            IconButton(
              tooltip: AppStrings.t(lang, 'signNewChat'),
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: _newConversation,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Hands ─────────────────────────────────────────────────────────
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                Positioned.fill(
                  child: _use3d
                      ? SignAvatarView(
                          signs: _signs,
                          playToken: _playToken,
                          speed: _slow ? 0.5 : 1.0,
                          onSignIndex: (i) {
                            if (mounted) setState(() => _current = i);
                          },
                          onAvailable: (ok) {
                            if (!ok && mounted) setState(() => _use3d = false);
                          },
                        )
                      : SignHandView(
                          signs: _signs,
                          playToken: _playToken,
                          speed: _slow ? 0.5 : 1.0,
                          onSignIndex: (i) {
                            if (mounted) setState(() => _current = i);
                          },
                        ),
                ),
                Positioned(
                  left: AppSpace.lg,
                  top: AppSpace.sm,
                  child: Text(AppStrings.t(lang, 'signDragHint'),
                      style: AppText.micro
                          .copyWith(color: AppPalette.textTertiary)),
                ),
                Positioned(
                  right: AppSpace.lg,
                  bottom: AppSpace.md,
                  child: AnimatedOpacity(
                    opacity: _current == null ? 0 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.md, vertical: AppSpace.xs),
                      decoration: AppDecor.floatingPanel,
                      child: Text(
                        _current == null || _current! >= _signs.length
                            ? ''
                            : _label(_signs[_current!], lang),
                        style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.textPrimary),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Sign strip ────────────────────────────────────────────────────
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
              itemCount: _signs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 4),
              itemBuilder: (_, i) => Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm, vertical: 3),
                  decoration: BoxDecoration(
                    color: i == _current
                        ? AppPalette.accent
                        : AppPalette.surfaceRaised,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(_label(_signs[i], lang),
                      style: AppText.label.copyWith(
                          color: i == _current
                              ? AppPalette.onAccent
                              : AppPalette.textSecondary)),
                ),
              ),
            ),
          ),

          // ── Conversation ──────────────────────────────────────────────────
          Expanded(
            flex: 5,
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.lg),
              children: [
                if (_turns.isEmpty) ...[
                  Text(AppStrings.t(lang, 'signWhereTo'),
                      style: AppText.heading),
                  const SizedBox(height: AppSpace.sm),
                  _PlaceGrid(lang: lang, onTap: _goTo, limit: 6),
                  const SizedBox(height: AppSpace.md),
                  Text(AppStrings.t(lang, 'signOtherPlace'),
                      style: AppText.label),
                  const SizedBox(height: AppSpace.xs),
                  _PlaceSearch(lang: lang, onPick: _goTo),
                  if (configured) ...[
                    const SizedBox(height: AppSpace.md),
                    Row(children: [
                      for (final (icon, key) in const [
                        (Icons.schedule_rounded, 'signQNextBus'),
                        (Icons.place_rounded, 'signQNearestStop'),
                        (Icons.support_rounded, 'signQHelp'),
                      ])
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: _PictureButton(
                              icon: icon,
                              label: AppStrings.t(lang, key),
                              onTap: () =>
                                  _ask(AppStrings.t(lang, key), icon: icon),
                            ),
                          ),
                        ),
                    ]),
                  ],
                ],
                for (var t = 0; t < _turns.length; t++)
                  _TurnView(
                    turn: _turns[t],
                    activeStep: _playingTurn == t ? _currentStep : null,
                    onReplay: () => _playTurn(t),
                    onStep: (s) => _playStep(t, s),
                    onCard: _showCard,
                    onSpeak: _speak,
                    lang: lang,
                  ),
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: Row(children: [
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: AppSpace.sm),
                      Text(AppStrings.t(lang, 'signPlanning'),
                          style: AppText.caption),
                    ]),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: Text(_error!,
                        style:
                            AppText.caption.copyWith(color: AppPalette.danger)),
                  ),
                const SizedBox(height: AppSpace.sm),
                Text(AppStrings.t(lang, 'signDisclaimer'),
                    style:
                        AppText.micro.copyWith(color: AppPalette.textTertiary)),
              ],
            ),
          ),

          // ── Input bar ─────────────────────────────────────────────────────
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.sm, AppSpace.xs, AppSpace.sm, AppSpace.sm),
              child: Row(children: [
                IconButton(
                  tooltip: AppStrings.t(lang, 'signPlaces'),
                  icon: const Icon(Icons.place_rounded,
                      color: AppPalette.accent),
                  onPressed: () => _showPlaces(lang),
                ),
                IconButton(
                  tooltip: AppStrings.t(lang, 'signWords'),
                  icon: const Icon(Icons.sign_language_rounded,
                      color: AppPalette.accent),
                  onPressed: () => _showWords(lang),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    style: AppText.body,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: AppStrings.t(
                          lang, configured ? 'signAskHint' : 'signTypeHint'),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: AppStrings.t(
                      lang, _listening ? 'voiceStop' : 'voiceTapToTalk'),
                  onPressed: _loading ? null : _listen,
                  style: _listening
                      ? IconButton.styleFrom(
                          backgroundColor: AppPalette.danger)
                      : null,
                  icon: Icon(
                    _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                    color: _listening ? Colors.white : AppPalette.accent,
                  ),
                ),
                IconButton.filled(
                  tooltip: AppStrings.t(
                      lang, configured ? 'signAskAi' : 'signShow'),
                  onPressed: _loading ? null : _send,
                  icon: Icon(configured
                      ? Icons.send_rounded
                      : Icons.back_hand_outlined),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Widgets ─────────────────────────────────────────────────────────────────

/// Search for any destination (typed or spoken). Curated places appear
/// instantly; Google (which knows shops such as "NOVA") and OpenStreetMap
/// fill in after a short pause. Works without AI.
class _PlaceSearch extends StatefulWidget {
  final AppLanguage lang;
  final ValueChanged<PlaceResult> onPick;
  const _PlaceSearch({required this.lang, required this.onPick});

  @override
  State<_PlaceSearch> createState() => _PlaceSearchState();
}

class _PlaceSearchState extends State<_PlaceSearch> {
  static const _taichung = LatLng(24.1477, 120.6736);
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<PlaceResult> _results = const [];
  bool _searching = false;
  bool _listening = false;
  bool _searched = false;
  int _query = 0; // drops results of superseded searches

  @override
  void dispose() {
    _debounce?.cancel();
    if (_listening) VoiceService.instance.stopListening();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    setState(() {
      _results = q.trim().isEmpty ? const [] : filterPopularPlaces(q).take(3).toList();
      _searched = false;
    });
    if (q.trim().length >= 2) {
      _debounce = Timer(const Duration(milliseconds: 600), () => _search(q));
    }
  }

  Future<void> _search(String q) async {
    q = q.trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    final id = ++_query;
    setState(() => _searching = true);
    final origin = await AssistantContext.position() ?? _taichung;
    final found = await Future.wait([
      TripPlanner.findPlace(origin, [q]),
      searchPlaces(q, origin),
    ]);
    if (!mounted || id != _query) return;
    final google = found[0] as PlaceResult?;
    final osm = found[1] as List<PlaceResult>;
    final seen = <String>{};
    setState(() {
      _searching = false;
      _searched = true;
      _results = [
        if (google != null) google,
        ...osm,
      ].where((p) => seen.add('${p.lat.toStringAsFixed(3)},'
          '${p.lon.toStringAsFixed(3)}')).take(5).toList();
    });
  }

  Future<void> _listen() async {
    final voice = VoiceService.instance;
    if (_listening) {
      await voice.stopListening();
      return;
    }
    setState(() => _listening = true);
    final text = await voice.listen(
      lang: widget.lang,
      onPartial: (w) {
        if (mounted) _ctrl.text = w;
      },
    );
    if (!mounted) return;
    setState(() => _listening = false);
    if (text == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(voice.unavailableMessage(widget.lang))));
    } else if (text.isNotEmpty) {
      _ctrl.text = text;
      _search(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = widget.lang;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _ctrl,
          style: AppText.body,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: AppStrings.t(
                lang, _listening ? 'voiceListening' : 'signSearchPlace'),
            prefixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : const Icon(Icons.search_rounded),
            suffixIcon: IconButton(
              tooltip: AppStrings.t(
                  lang, _listening ? 'voiceStop' : 'voiceTapToTalk'),
              icon: Icon(
                  _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: _listening ? AppPalette.danger : AppPalette.accent),
              onPressed: _listen,
            ),
          ),
        ),
        for (final p in _results)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
            leading: Icon(_placeIcon(p), color: AppPalette.accent),
            title: Text(
                lang == AppLanguage.en && p.shortNameEn.isNotEmpty
                    ? p.shortNameEn
                    : p.shortName,
                style: AppText.bodyStrong),
            subtitle: p.displayName == p.shortName
                ? null
                : Text(p.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption),
            trailing: const Icon(Icons.directions_bus_rounded,
                color: AppPalette.textTertiary, size: 20),
            onTap: () {
              FocusScope.of(context).unfocus();
              widget.onPick(p);
            },
          ),
        if (_searched && _results.isEmpty && !_searching)
          Padding(
            padding: const EdgeInsets.all(AppSpace.sm),
            child: Text(AppStrings.t(lang, 'signNoPlace'),
                style: AppText.caption),
          ),
      ],
    );
  }
}

class _PlaceGrid extends StatelessWidget {
  final AppLanguage lang;
  final ValueChanged<PlaceResult> onTap;
  final int? limit;
  const _PlaceGrid({required this.lang, required this.onTap, this.limit});

  @override
  Widget build(BuildContext context) {
    final places = limit == null ? popularPlaces : popularPlaces.take(limit!);
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppSpace.sm,
      crossAxisSpacing: AppSpace.sm,
      childAspectRatio: 1.15,
      children: [
        for (final p in places)
          _PictureButton(
            icon: _placeIcon(p),
            label: lang == AppLanguage.en && p.shortNameEn.isNotEmpty
                ? p.shortNameEn
                : p.shortName,
            onTap: () => onTap(p),
          ),
      ],
    );
  }
}

class _TurnView extends StatelessWidget {
  final _Turn turn;
  final int? activeStep;
  final VoidCallback onReplay;
  final ValueChanged<int> onStep;
  final ValueChanged<String> onCard;
  final ValueChanged<String> onSpeak;
  final AppLanguage lang;

  const _TurnView({
    required this.turn,
    required this.activeStep,
    required this.onReplay,
    required this.onStep,
    required this.onCard,
    required this.onSpeak,
    required this.lang,
  });

  @override
  Widget build(BuildContext context) {
    final a = turn.answer;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The passenger's question
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md, vertical: AppSpace.sm),
              decoration: BoxDecoration(
                color: AppPalette.accent,
                borderRadius: BorderRadius.circular(AppRadius.lg),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (turn.questionIcon != null) ...[
                  Icon(turn.questionIcon,
                      size: 22, color: AppPalette.onAccent),
                  const SizedBox(width: AppSpace.xs),
                ],
                Flexible(
                  child: Text(turn.question,
                      style:
                          AppText.bodyStrong.copyWith(color: AppPalette.onAccent)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          // The answer
          Container(
            decoration: BoxDecoration(
              color: AppPalette.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < a.steps.length; i++)
                  _StepRow(
                    step: a.steps[i],
                    index: i,
                    active: activeStep == i,
                    onTap: () => onStep(i),
                    onCard: a.steps[i].card.isEmpty
                        ? null
                        : () => onCard(a.steps[i].card),
                    lang: lang,
                  ),
                Row(children: [
                  const SizedBox(width: AppSpace.md),
                  if (a.reply.isNotEmpty)
                    Expanded(
                        child: Text(a.reply,
                            style: AppText.caption, maxLines: 3))
                  else
                    const Spacer(),
                  if (a.reply.isNotEmpty)
                    IconButton(
                      tooltip: AppStrings.t(lang, 'signSpeak'),
                      icon: const Icon(Icons.volume_up_rounded, size: 20),
                      onPressed: () => onSpeak(a.reply),
                    ),
                  IconButton(
                    tooltip: AppStrings.t(lang, 'signReplay'),
                    icon: const Icon(Icons.replay_rounded, size: 20),
                    onPressed: onReplay,
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final SignStep step;
  final int index;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onCard;
  final AppLanguage lang;

  const _StepRow({
    required this.step,
    required this.index,
    required this.active,
    required this.onTap,
    required this.onCard,
    required this.lang,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppPalette.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md, vertical: AppSpace.sm),
          child: Row(children: [
            // Step number + pictogram, readable without text
            CircleAvatar(
              radius: 11,
              backgroundColor:
                  active ? AppPalette.accent : AppPalette.surfaceRaised,
              child: Text('${index + 1}',
                  style: AppText.micro.copyWith(
                      color: active
                          ? AppPalette.onAccent
                          : AppPalette.textSecondary)),
            ),
            const SizedBox(width: AppSpace.sm),
            Icon(pictogramIcons[step.pictogram] ?? Icons.help_outline_rounded,
                size: 34, color: AppPalette.accent),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (step.bigText.isNotEmpty)
                    Text(step.bigText,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                            color: AppPalette.textPrimary)),
                  if (step.text.isNotEmpty)
                    Text(step.text, style: AppText.caption),
                ],
              ),
            ),
            if (onCard != null)
              IconButton(
                tooltip: AppStrings.t(lang, 'signShowDriver'),
                icon: const Icon(Icons.badge_outlined,
                    color: AppPalette.warning),
                onPressed: onCard,
              ),
          ]),
        ),
      ),
    );
  }
}

/// Large icon-first button for people who can't rely on the label.
class _PictureButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _PictureButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppPalette.surfaceRaised,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: AppSpace.sm, horizontal: AppSpace.xs),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 32, color: AppPalette.accent),
              const SizedBox(height: AppSpace.xs),
              Text(label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.micro),
            ],
          ),
        ),
      ),
    );
  }
}
