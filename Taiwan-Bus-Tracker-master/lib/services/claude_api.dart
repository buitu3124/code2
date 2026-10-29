// Claude API client for the in-app AI assistant.
//
// Dart has no official Anthropic SDK, so this talks to the Messages API over
// raw HTTP (POST /v1/messages) with the `http` package already used for PTX.
//
// Configuration (compile-time, never hard-code a key in source):
//   flutter run --dart-define=ANTHROPIC_API_KEY=sk-ant-...
// For a release build, point the app at your own backend proxy instead so the
// key never ships inside the APK:
//   flutter run --dart-define=ANTHROPIC_BASE_URL=https://your-proxy.example.com
// The proxy forwards /v1/messages to api.anthropic.com and adds the key.
//
// Conversations are kept as raw Messages API history and only ever appended
// to: every assistant turn goes back exactly as returned (thinking, tool_use
// and fallback blocks included), which multi-turn tool use requires.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class ClaudeException implements Exception {
  final String message;
  const ClaudeException(this.message);
  @override
  String toString() => message;
}

typedef ToolRunner = Future<String> Function(
    String name, Map<String, dynamic> input);

class ClaudeApi {
  ClaudeApi._();

  static const _apiKey = String.fromEnvironment('ANTHROPIC_API_KEY');
  static const _baseUrl = String.fromEnvironment('ANTHROPIC_BASE_URL',
      defaultValue: 'https://api.anthropic.com');
  static const model = 'claude-opus-5-5';

  /// Lets tests exercise the request code with a mocked HTTP client.
  @visibleForTesting
  static bool debugForceConfigured = false;

  /// True when either a key or a proxy is configured.
  static bool get isConfigured =>
      debugForceConfigured ||
      _apiKey.isNotEmpty ||
      _baseUrl != 'https://api.anthropic.com';

  static Map<String, String> get _headers => {
        'content-type': 'application/json',
        'anthropic-version': '2023-06-01',
        // Re-runs a safety-classifier decline on Anthropic's recommended
        // fallback model inside the same request.
        'anthropic-beta': 'server-side-fallback-2026-07-01',
        if (_apiKey.isNotEmpty) 'x-api-key': _apiKey,
      };

  static Map<String, dynamic> _body({
    required String system,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    Map<String, dynamic>? schema,
  }) =>
      {
        'model': model,
        'max_tokens': 4096,
        'fallbacks': 'default',
        // Assistant replies are short and latency-sensitive.
        'output_config': {
          'effort': 'low',
          if (schema != null) 'format': {'type': 'json_schema', 'schema': schema},
        },
        'system': system,
        if (tools.isNotEmpty) 'tools': tools,
        'messages': messages,
      };

  static void _ensureConfigured() {
    if (!isConfigured) {
      throw const ClaudeException(
          'AI assistant is not configured. Run with '
          '--dart-define=ANTHROPIC_API_KEY=... or ANTHROPIC_BASE_URL=...');
    }
  }

  static ClaudeException _httpError(int status, String body) {
    String detail = body;
    try {
      detail = (jsonDecode(body)['error']?['message'] as String?) ?? body;
    } catch (_) {}
    if (status == 401) return const ClaudeException('Invalid API key (401)');
    if (status == 429) {
      return const ClaudeException('Rate limited — try again shortly (429)');
    }
    if (status >= 500) return ClaudeException('Claude service error ($status)');
    return ClaudeException('Request failed ($status): $detail');
  }

  static const _refused =
      ClaudeException('The assistant could not answer this request.');

  /// Runs every tool_use block of an assistant turn and returns the single
  /// user message carrying all results.
  static Future<Map<String, dynamic>> _toolResults(
      List<Map<String, dynamic>> content, ToolRunner runTool) async {
    final results = <Map<String, dynamic>>[];
    for (final block in content.where((b) => b['type'] == 'tool_use')) {
      String out;
      var isError = false;
      if (block['_invalid'] == true) {
        out = 'INVALID_JSON: the tool input was not valid JSON. '
            'Call the tool again.';
        isError = true;
      } else {
        try {
          out = await runTool(block['name'] as String,
              (block['input'] as Map).cast<String, dynamic>());
        } catch (e) {
          out = 'Tool failed: $e';
          isError = true;
        }
      }
      results.add({
        'type': 'tool_result',
        'tool_use_id': block['id'],
        'content': out,
        if (isError) 'is_error': true,
      });
    }
    return {'role': 'user', 'content': results};
  }

  /// Streams a reply, running [tools] whenever Claude calls them. Each event
  /// is the full visible text so far. [messages] is extended in place with
  /// the assistant turn(s) and tool results.
  ///
  /// Tools should set `eager_input_streaming: true`; their inputs are then
  /// parsed and validated here (invalid JSON goes back as an error result).
  static Stream<String> streamWithTools({
    required String system,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    ToolRunner? runTool,
    int maxRounds = 4,
  }) async* {
    _ensureConfigured();
    var shown = '';
    for (var round = 0; round <= maxRounds; round++) {
      final req = http.Request('POST', Uri.parse('$_baseUrl/v1/messages'))
        ..headers.addAll(_headers)
        ..body = jsonEncode({
          ..._body(system: system, messages: messages, tools: tools),
          'stream': true,
        });
      final client = http.Client();
      final blocks = <int, Map<String, dynamic>>{};
      final partialJson = <int, StringBuffer>{};
      final text = StringBuffer();
      String? stopReason;
      try {
        final res =
            await client.send(req).timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) {
          throw _httpError(res.statusCode, await res.stream.bytesToString());
        }
        await for (final line in res.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!line.startsWith('data:')) continue;
          final Map<String, dynamic> event;
          try {
            event =
                jsonDecode(line.substring(5).trim()) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
          final index = event['index'] as int?;
          switch (event['type']) {
            case 'content_block_start':
              final block = Map<String, dynamic>.from(
                  event['content_block'] as Map<String, dynamic>);
              blocks[index!] = block;
              if (block['type'] == 'tool_use') {
                partialJson[index] = StringBuffer();
              }
              // A fallback block marks the switch to another model: what
              // the declined model wrote so far is not the answer.
              if (block['type'] == 'fallback') {
                text.clear();
                yield shown;
              }
            case 'content_block_delta':
              final delta = event['delta'] as Map<String, dynamic>;
              final block = blocks[index];
              if (block == null) break;
              switch (delta['type']) {
                case 'text_delta':
                  final t = delta['text'] as String;
                  block['text'] = (block['text'] as String? ?? '') + t;
                  text.write(t);
                  yield shown + text.toString();
                case 'input_json_delta':
                  partialJson[index]?.write(delta['partial_json'] as String);
                case 'thinking_delta':
                  block['thinking'] = (block['thinking'] as String? ?? '') +
                      (delta['thinking'] as String);
                case 'signature_delta':
                  block['signature'] = delta['signature'];
              }
            case 'content_block_stop':
              final block = blocks[index];
              if (block?['type'] == 'tool_use') {
                final raw = partialJson[index].toString();
                try {
                  block!['input'] = raw.isEmpty
                      ? <String, dynamic>{}
                      : jsonDecode(raw) as Map<String, dynamic>;
                } catch (_) {
                  block!['input'] = <String, dynamic>{};
                  block['_invalid'] = true;
                }
              }
            case 'message_delta':
              stopReason =
                  (event['delta'] as Map?)?['stop_reason'] as String?;
            case 'error':
              throw ClaudeException(
                  (event['error'] as Map?)?['message'] as String? ??
                      'Stream error');
          }
        }
      } on TimeoutException {
        throw const ClaudeException('Connection timed out');
      } finally {
        client.close();
      }

      if (stopReason == 'refusal') throw _refused;
      final ordered = (blocks.keys.toList()..sort()).map((k) => blocks[k]!);
      final content = [
        for (final b in ordered)
          Map<String, dynamic>.from(b)..remove('_invalid'),
      ];
      messages.add({'role': 'assistant', 'content': content});

      if (stopReason == 'tool_use' && runTool != null && round < maxRounds) {
        messages.add(await _toolResults(ordered.toList(), runTool));
        if (text.isNotEmpty) shown = '$shown$text\n\n';
        continue;
      }
      if (stopReason == 'max_tokens') {
        throw const ClaudeException('The reply was cut off.');
      }
      return;
    }
    throw const ClaudeException('The assistant took too many steps.');
  }

  /// Non-streaming tool-use loop whose final answer matches [schema];
  /// returns the parsed JSON. [messages] is extended in place.
  static Future<Map<String, dynamic>> structuredWithTools({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
    List<Map<String, dynamic>> tools = const [],
    ToolRunner? runTool,
    int maxRounds = 4,
  }) async {
    _ensureConfigured();
    for (var round = 0; round <= maxRounds; round++) {
      final http.Response res;
      try {
        res = await http
            .post(Uri.parse('$_baseUrl/v1/messages'),
                headers: _headers,
                body: jsonEncode(_body(
                    system: system,
                    messages: messages,
                    tools: tools,
                    schema: schema)))
            .timeout(const Duration(seconds: 90));
      } on TimeoutException {
        throw const ClaudeException('Connection timed out');
      }
      if (res.statusCode != 200) {
        throw _httpError(res.statusCode, utf8.decode(res.bodyBytes));
      }
      final json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final stop = json['stop_reason'];
      if (stop == 'refusal') throw _refused;
      final content = (json['content'] as List).cast<Map<String, dynamic>>();
      messages.add({'role': 'assistant', 'content': content});

      if (stop == 'tool_use' && runTool != null) {
        if (round == maxRounds) break;
        messages.add(await _toolResults(content, runTool));
        continue;
      }

      final texts = content
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] as String)
          .toList();
      if (texts.isEmpty) throw const ClaudeException('Empty response');
      return jsonDecode(texts.last) as Map<String, dynamic>;
    }
    throw const ClaudeException('The assistant took too many steps.');
  }
}
