// AI Chat — a chat panel backed by Claude. Replies stream in token by token,
// are grounded in live data (nearby stops + arrivals), and Claude can plan a
// bus trip to any place with the plan_trip tool.
//
// Voice: tap the mic to speak a message; replies to spoken messages are read
// aloud. In voice-conversation mode the app keeps listening after each
// answer, for a hands-free back-and-forth.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../design/tokens.dart';
import '../providers/bus_providers.dart';
import '../services/assistant_context.dart';
import '../services/assistant_tools.dart';
import '../services/claude_api.dart';
import '../services/voice_service.dart';
import '../utils/app_strings.dart';

String chatSystemPrompt(AppLanguage lang) => '''
You are the assistant inside Taiwan Bus Tracker, a real-time bus app for Taichung, Taiwan.
Help passengers with: which bus to take, when buses arrive, where stops are, and how to use the app.

When the passenger wants to go somewhere, call plan_trip and describe the result simply: walk to which stop, which bus number (and when it arrives, if known), how many stops, where to get off, and the last walk.

App features you can point people to:
- Map tab: search a place in the top bar to get bus directions; the bottom sheet has "Nearby" stops and "Routes".
- Tap a stop or route to see live arrival times; tap the star to save a route to the "Saved" tab.
- Scan button (in the search bar): photograph a bus stop sign to read its route numbers.
- Hold the microphone button on the map to ask by voice.
- 中/EN switches language. The AI button opens this chat or the sign-language assistant.

Rules:
- Reply in ${lang == AppLanguage.zh ? 'Traditional Chinese (繁體中文)' : 'English'} unless the passenger writes in another language, then match theirs.
- Keep replies short and easy to read on a phone; they may also be read aloud, so use plain sentences — no markdown, tables or symbols.
- Only state bus times, routes or stop names that come from plan_trip or the live data in the passenger's message. Never invent them.
- For emergencies, tell the passenger to call 119 (fire/ambulance) or 110 (police).''';

class AiChatScreen extends ConsumerStatefulWidget {
  /// Optional exchange to continue from (e.g. a question asked by voice on
  /// the map).
  final String? initialQuestion;
  final String? initialAnswer;

  const AiChatScreen({super.key, this.initialQuestion, this.initialAnswer});

  @override
  ConsumerState<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends ConsumerState<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _voice = VoiceService.instance;

  /// What the chat shows: (fromUser, text).
  final List<(bool, String)> _bubbles = [];

  /// Raw Messages API history (append-only).
  final List<Map<String, dynamic>> _api = [];
  AppLanguage? _convLang; // fixed for the conversation: keeps the system
  // prompt identical across turns

  String? _streaming; // assistant text while a reply is arriving
  String? _error;
  StreamSubscription<String>? _sub;

  bool _listening = false;
  bool _handsFree = false;

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuestion, a = widget.initialAnswer;
    if (q != null && q.isNotEmpty && a != null && a.isNotEmpty) {
      _bubbles
        ..add((true, q))
        ..add((false, a));
      _api
        ..add({'role': 'user', 'content': q})
        ..add({'role': 'assistant', 'content': a});
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _voice.stopListening();
    _voice.stopSpeaking();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _busy => _streaming != null;

  Future<void> _send(String text, {bool byVoice = false}) async {
    text = text.trim();
    if (text.isEmpty || _busy) return;
    _convLang ??= ref.read(languageProvider);
    final lang = _convLang!;
    _input.clear();
    final rollback = _api.length;
    setState(() {
      _bubbles.add((true, text));
      _streaming = '';
      _error = null;
    });
    _scrollToEnd();

    // Live data rides in the user turn, so the system prompt never changes.
    final live = await AssistantContext.load();
    if (!mounted) return;
    _api.add({
      'role': 'user',
      'content': 'Live data:\n$live\n\nPassenger: $text',
    });
    // Spoken questions get spoken answers, read sentence by sentence while
    // the reply is still streaming in.
    final speaker = byVoice || _handsFree ? SentenceSpeaker(lang) : null;
    _sub = ClaudeApi.streamWithTools(
      system: chatSystemPrompt(lang),
      messages: _api,
      tools: [planTripTool(streaming: true)],
      runTool: (name, input) => name == 'plan_trip'
          ? runPlanTrip(input, lang)
          : Future.value('Unknown tool $name'),
    ).listen(
      (soFar) {
        setState(() => _streaming = soFar);
        speaker?.update(soFar);
        _scrollToEnd();
      },
      onError: (Object e) {
        // Drop the unanswered exchange so the history stays valid and a
        // retry resends it cleanly.
        _api.removeRange(rollback, _api.length);
        setState(() {
          _error = e.toString();
          _streaming = null;
          _bubbles.removeLast();
          _input.text = text;
        });
      },
      onDone: () {
        final reply = _streaming;
        if (reply == null) return; // error already handled
        setState(() {
          if (reply.isNotEmpty) _bubbles.add((false, reply));
          _streaming = null;
        });
        if (speaker != null && reply.isNotEmpty) {
          speaker.finish(reply).then((_) {
            // Hands-free: listen for the next question once the answer ends.
            if (mounted && _handsFree && !_busy && !_listening) _listen();
          });
        }
      },
      cancelOnError: true,
    );
  }

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
      lang: ref.read(languageProvider),
      onPartial: (w) {
        if (mounted) _input.text = w;
      },
    );
    if (!mounted) return;
    setState(() => _listening = false);
    if (text == null) {
      setState(() => _error =
          _voice.unavailableMessage(ref.read(languageProvider)));
    } else if (text.isNotEmpty) {
      _send(text, byVoice: true);
    }
  }

  void _toggleHandsFree() {
    final lang = ref.read(languageProvider);
    setState(() => _handsFree = !_handsFree);
    if (_handsFree) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.t(lang, 'voiceHandsFreeOn'))));
      if (!_listening && !_busy) _listen();
    } else {
      _voice.stopListening();
      _voice.stopSpeaking();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut);
      }
    });
  }

  void _clear() {
    _sub?.cancel();
    _voice.stopSpeaking();
    setState(() {
      _bubbles.clear();
      _api.clear();
      _convLang = null;
      _streaming = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lang = ref.watch(languageProvider);
    final configured = ClaudeApi.isConfigured;

    final bubbles = <Widget>[
      _Bubble(text: AppStrings.t(lang, 'chatWelcome'), fromUser: false),
      for (final (fromUser, text) in _bubbles)
        _Bubble(
          text: text,
          fromUser: fromUser,
          onSpeak: fromUser ? null : () => _voice.speak(text, lang),
        ),
      if (_streaming != null)
        _Bubble(
          text: _streaming!.isEmpty
              ? AppStrings.t(lang, 'aiThinking')
              : _streaming!,
          fromUser: false,
          pending: _streaming!.isEmpty,
        ),
      if (_error != null) _ErrorNote(message: _error!),
    ];

    return Scaffold(
      backgroundColor: AppPalette.canvas,
      appBar: AppBar(
        title: Text(AppStrings.t(lang, 'assistantChatTitle')),
        actions: [
          if (configured)
            IconButton(
              tooltip: AppStrings.t(lang, 'voiceHandsFree'),
              isSelected: _handsFree,
              icon: const Icon(Icons.headset_mic_outlined),
              selectedIcon:
                  const Icon(Icons.headset_mic, color: AppPalette.accent),
              onPressed: _toggleHandsFree,
            ),
          if (_bubbles.isNotEmpty)
            IconButton(
              tooltip: AppStrings.t(lang, 'chatClear'),
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _clear,
            ),
        ],
      ),
      body: Column(
        children: [
          if (!configured)
            Container(
              width: double.infinity,
              color: AppPalette.warning.withValues(alpha: 0.15),
              padding: const EdgeInsets.all(AppSpace.md),
              child: Text(AppStrings.t(lang, 'aiNotConfigured'),
                  style: AppText.caption.copyWith(color: AppPalette.warning)),
            ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(AppSpace.lg),
              children: bubbles,
            ),
          ),
          if (_bubbles.isEmpty && !_busy)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                children: [
                  for (final key in const [
                    'chatSuggestNextBus',
                    'chatSuggestStation',
                    'chatSuggestScan',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpace.sm),
                      child: ActionChip(
                        label: Text(AppStrings.t(lang, key)),
                        onPressed: configured
                            ? () => _send(AppStrings.t(lang, key))
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpace.md, AppSpace.sm, AppSpace.sm, AppSpace.sm),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: configured,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _send,
                    style: AppText.body,
                    decoration: InputDecoration(
                      hintText: AppStrings.t(lang,
                          _listening ? 'voiceListening' : 'chatHint'),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.xs),
                _MicButton(
                  listening: _listening,
                  tooltip: AppStrings.t(
                      lang, _listening ? 'voiceStop' : 'voiceTapToTalk'),
                  onPressed: configured && !_busy ? _listen : null,
                ),
                IconButton.filled(
                  onPressed:
                      configured && !_busy ? () => _send(_input.text) : null,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send_rounded),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mic button that pulses red while listening.
class _MicButton extends StatelessWidget {
  final bool listening;
  final String tooltip;
  final VoidCallback? onPressed;
  const _MicButton(
      {required this.listening, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: listening
          ? IconButton.styleFrom(backgroundColor: AppPalette.danger)
          : null,
      icon: Icon(
        listening ? Icons.mic_rounded : Icons.mic_none_rounded,
        color: listening ? Colors.white : AppPalette.accent,
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  final bool fromUser;
  final bool pending;
  final VoidCallback? onSpeak;
  const _Bubble({
    required this.text,
    required this.fromUser,
    this.pending = false,
    this.onSpeak,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.8),
        margin: const EdgeInsets.only(bottom: AppSpace.sm),
        padding: EdgeInsets.fromLTRB(
            AppSpace.md, AppSpace.sm + 2, onSpeak == null ? AppSpace.md : 2,
            AppSpace.sm + 2),
        decoration: BoxDecoration(
          color: fromUser ? AppPalette.accent : AppPalette.surfaceRaised,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(AppRadius.lg),
            topRight: const Radius.circular(AppRadius.lg),
            bottomLeft: Radius.circular(fromUser ? AppRadius.lg : 4),
            bottomRight: Radius.circular(fromUser ? 4 : AppRadius.lg),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SelectableText(
                text,
                style: AppText.body.copyWith(
                  color: fromUser
                      ? AppPalette.onAccent
                      : pending
                          ? AppPalette.textTertiary
                          : AppPalette.textPrimary,
                ),
              ),
            ),
            if (onSpeak != null)
              _SpeakButton(onTap: onSpeak!),
          ],
        ),
      ),
    );
  }
}

/// Small "read aloud" button inside an assistant bubble.
class _SpeakButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SpeakButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: const Icon(Icons.volume_up_rounded,
          size: 16, color: AppPalette.textTertiary),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: EdgeInsets.zero,
    );
  }
}

class _ErrorNote extends StatelessWidget {
  final String message;
  const _ErrorNote({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(children: [
        const Icon(Icons.error_outline_rounded,
            size: 16, color: AppPalette.danger),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: Text(message,
              style: AppText.caption.copyWith(color: AppPalette.danger)),
        ),
      ]),
    );
  }
}
