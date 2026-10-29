// Voice in / voice out shared by the map, the AI chat and the sign-language
// assistant: speech-to-text that stops by itself when the speaker pauses,
// and text-to-speech that can be awaited and queued sentence by sentence
// (so a streamed answer is read aloud while it is still being written).

import 'dart:async';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../utils/app_strings.dart';

class VoiceService {
  VoiceService._();
  static final instance = VoiceService._();

  final _stt = SpeechToText();
  final _tts = FlutterTts();
  bool? _sttReady;
  bool _ttsReady = false;
  AppLanguage? _ttsLang;
  final Map<AppLanguage, String?> _localeIds = {};

  Completer<String>? _pending;
  String _words = '';
  // Status events from a previous session can arrive late; only 'done'
  // after this session reported 'listening' ends it.
  bool _sessionLive = false;
  bool _permissionDenied = false;

  bool get isListening => _pending != null;

  /// Why the last [listen] returned null, for the user.
  String unavailableMessage(AppLanguage lang) => AppStrings.t(
      lang, _permissionDenied ? 'voiceNoPermission' : 'voiceUnavailable');

  // ── Speech to text ────────────────────────────────────────────────────

  Future<bool> _ensureStt() async {
    if (_sttReady == true) return true;
    try {
      _sttReady = await _stt.initialize(
        onStatus: (status) {
          if (status == 'listening') _sessionLive = true;
          if ((status == 'done' || status == 'notListening') && _sessionLive) {
            _finish();
          }
        },
        onError: (SpeechRecognitionError e) {
          if (e.errorMsg.contains('permission')) _permissionDenied = true;
          if (_sessionLive || e.permanent) _finish();
        },
      );
      if (_sttReady != true) {
        _permissionDenied = !await _stt.hasPermission;
      }
    } catch (_) {
      _sttReady = false;
    }
    return _sttReady!;
  }

  /// The recognizer's own id for [lang]: Android names Taiwanese Mandarin
  /// differently across versions (zh_TW, zh-TW, cmn-Hant-TW, …).
  Future<String?> _localeFor(AppLanguage lang) async {
    if (_localeIds.containsKey(lang)) return _localeIds[lang];
    String norm(String s) => s.toLowerCase().replaceAll('-', '_');
    final wanted = lang == AppLanguage.zh
        ? ['zh_tw', 'cmn_hant_tw', 'zh_hant_tw', 'zh_hk', 'cmn_hans_cn', 'zh_cn']
        : ['en_us', 'en_gb', 'en_au'];
    String? found;
    try {
      final ids = (await _stt.locales()).map((l) => l.localeId).toList();
      for (final w in wanted) {
        found = ids.where((id) => norm(id) == w).firstOrNull;
        if (found != null) break;
      }
      found ??= ids
          .where((id) => lang == AppLanguage.zh
              ? norm(id).startsWith('zh') || norm(id).startsWith('cmn')
              : norm(id).startsWith('en'))
          .firstOrNull;
    } catch (_) {}
    // Unknown list: ask for the standard id and let the engine decide.
    return _localeIds[lang] =
        found ?? (lang == AppLanguage.zh ? 'zh_TW' : 'en_US');
  }

  void _finish() {
    _sessionLive = false;
    final c = _pending;
    _pending = null;
    if (c != null && !c.isCompleted) c.complete(_words.trim());
  }

  /// Listens until the speaker pauses and returns what was said ('' if
  /// nothing). Returns null when speech recognition is unavailable — see
  /// [unavailableMessage].
  Future<String?> listen({
    required AppLanguage lang,
    void Function(String words)? onPartial,
  }) async {
    if (!await _ensureStt()) return null;
    await stopSpeaking(); // don't transcribe our own voice
    if (_pending != null) await stopListening();
    _words = '';
    _sessionLive = false;
    final c = _pending = Completer<String>();
    final localeId = await _localeFor(lang);
    try {
      await _stt.listen(
        onResult: (r) {
          _words = r.recognizedWords;
          onPartial?.call(_words);
          if (r.finalResult) _finish();
        },
        listenOptions: SpeechListenOptions(
          localeId: localeId,
          listenFor: const Duration(seconds: 30),
          pauseFor: const Duration(seconds: 3),
          partialResults: true,
          listenMode: ListenMode.dictation,
          cancelOnError: true,
        ),
      );
    } catch (_) {
      _finish();
    }
    // Safety net if the engine never reports an end of this session.
    Timer(const Duration(seconds: 35), () {
      if (identical(_pending, c)) stopListening();
    });
    return c.future;
  }

  /// Stops listening; the pending [listen] completes with what was heard.
  Future<void> stopListening() async {
    if (_pending == null) return;
    try {
      await _stt.stop();
    } catch (_) {}
    _finish();
  }

  // ── Text to speech ────────────────────────────────────────────────────

  Future<void> _ensureTts(AppLanguage lang) async {
    if (!_ttsReady) {
      // Without this, speak() returns at once and a following listen()
      // would cut the answer off.
      await _tts.awaitSpeakCompletion(true);
      _ttsReady = true;
    }
    if (_ttsLang == lang) return;
    final options =
        lang == AppLanguage.zh ? ['zh-TW', 'zh-HK', 'zh-CN'] : ['en-US', 'en-GB'];
    for (final o in options) {
      try {
        if (await _tts.isLanguageAvailable(o) == true) {
          await _tts.setLanguage(o);
          break;
        }
      } catch (_) {}
    }
    _ttsLang = lang;
  }

  /// Text as it should be read aloud: no markdown, emoji or URLs.
  static String cleanForSpeech(String text) => text
      .replaceAll(RegExp(r'https?://\S+'), '')
      .replaceAll(RegExp(r'[*_#`>|~\[\]]'), '')
      .replaceAll(RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  int _generation = 0;
  Future<void> _queue = Future.value();

  /// Speaks [text]; completes when speaking has finished (or was stopped).
  Future<void> speak(String text, AppLanguage lang) async {
    await stopSpeaking();
    return enqueue(text, lang);
  }

  /// Speaks [text] after whatever is already queued; completes when this
  /// part has been spoken. [stopSpeaking] drops everything queued.
  Future<void> enqueue(String text, AppLanguage lang) {
    final clean = cleanForSpeech(text);
    final gen = _generation;
    _queue = _queue.then((_) async {
      if (gen != _generation || clean.isEmpty) return;
      try {
        await stopListening(); // the mic must not hear the answer
        await _ensureTts(lang);
        if (gen == _generation) {
          // Some engines never report completion; don't stall the queue.
          await _tts.speak(clean).timeout(
              Duration(seconds: 15 + clean.length ~/ 4),
              onTimeout: () => null);
        }
      } catch (_) {}
    });
    return _queue;
  }

  Future<void> stopSpeaking() async {
    _generation++;
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

/// Feeds a streamed answer to [VoiceService.enqueue] one sentence at a
/// time, so speaking starts as soon as the first sentence is complete.
class SentenceSpeaker {
  final AppLanguage lang;
  int _spoken = 0;
  Future<void> _last = Future.value();
  SentenceSpeaker(this.lang);

  static final _end = RegExp(r'[。！？!?；;\n]|[.](?=\s)');

  /// Call with the full text so far.
  void update(String soFar) {
    if (soFar.length < _spoken) _spoken = 0; // answer restarted (fallback)
    var cut = -1;
    for (final m in _end.allMatches(soFar, _spoken)) {
      cut = m.end;
    }
    if (cut > _spoken) {
      _last = VoiceService.instance
          .enqueue(soFar.substring(_spoken, cut), lang);
      _spoken = cut;
    }
  }

  /// Call with the final text; completes when everything has been spoken.
  Future<void> finish(String text) {
    if (text.length < _spoken) _spoken = 0;
    if (text.length > _spoken) {
      _last = VoiceService.instance.enqueue(text.substring(_spoken), lang);
      _spoken = text.length;
    }
    return _last;
  }
}
