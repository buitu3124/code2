// 3D human signer: a VRM avatar rendered with three.js in a WebView
// (assets/avatar, source in tool/avatar), driven by the same sign timelines
// as the 2D hands. Falls back to [SignHandView] where a WebView isn't
// available (web, desktop, tests) or the page fails to load (no WebGL).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../design/tokens.dart';
import 'sign_hand_view.dart';
import 'sign_vocabulary.dart';

/// Credit required by the model's licence (VRM Public License 1.0).
const avatarCredit = 'Seed-san © VirtualCast, Inc.';

/// True on platforms where the 3D avatar can run.
bool get avatarSupported =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Serves assets/avatar/ on the loopback interface. Android's WebView won't
/// let a file:// page fetch the model, so the page is loaded over HTTP.
class _AvatarServer {
  _AvatarServer._();
  static Future<Uri>? _uri;

  static Future<Uri> start() => _uri ??= _bind();

  static Future<Uri> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final name = req.uri.pathSegments.isEmpty
          ? 'index.html'
          : req.uri.pathSegments.join('/');
      // Only plain file names inside assets/avatar/.
      if (name.contains('..')) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      try {
        final data = await rootBundle.load('assets/avatar/$name');
        req.response.headers.contentType = switch (name.split('.').last) {
          'html' => ContentType.html,
          'js' => ContentType('application', 'javascript', charset: 'utf-8'),
          'json' => ContentType.json,
          _ => ContentType.binary,
        };
        req.response.add(data.buffer.asUint8List(
            data.offsetInBytes, data.lengthInBytes));
      } catch (_) {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });
    return Uri.parse('http://127.0.0.1:${server.port}/index.html');
  }
}

class SignAvatarView extends StatefulWidget {
  /// Sign ids from [signVocabulary]; unknown ids are skipped.
  final List<String> signs;

  /// Change this to replay the same sequence.
  final int playToken;

  /// 1.0 = normal; lower is slower.
  final double speed;

  /// Index into [signs] currently being signed, null between signs.
  final ValueChanged<int?>? onSignIndex;

  /// Shown while the model loads; also called with false if it can't run.
  final ValueChanged<bool>? onAvailable;

  const SignAvatarView({
    super.key,
    required this.signs,
    this.playToken = 0,
    this.speed = 1.0,
    this.onSignIndex,
    this.onAvailable,
  });

  @override
  State<SignAvatarView> createState() => _SignAvatarViewState();
}

class _SignAvatarViewState extends State<SignAvatarView> {
  WebViewController? _web;
  bool _ready = false;
  bool _failed = !avatarSupported;
  Timer? _loadTimeout;

  @override
  void initState() {
    super.initState();
    if (!_failed) _init();
  }

  Future<void> _init() async {
    try {
      final uri = await _AvatarServer.start();
      final web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(AppPalette.canvas)
        ..addJavaScriptChannel('AvatarBridge', onMessageReceived: _onMessage);
      await web.loadRequest(uri);
      if (!mounted) return;
      setState(() => _web = web);
      // A phone without WebGL never reports ready: use the 2D hands.
      _loadTimeout = Timer(const Duration(seconds: 25), () {
        if (!_ready) _fail();
      });
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (!mounted || _failed) return;
    setState(() => _failed = true);
    widget.onAvailable?.call(false);
  }

  void _onMessage(JavaScriptMessage m) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(m.message) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'ready':
        _loadTimeout?.cancel();
        setState(() => _ready = true);
        widget.onAvailable?.call(true);
        _play();
      case 'error':
        if (!_ready) _fail();
      case 'sign':
        widget.onSignIndex?.call(_originalIndex(msg['index'] as int?));
    }
  }

  /// Maps an index among the valid signs back to [SignAvatarView.signs].
  int? _originalIndex(int? idx) {
    if (idx == null) return null;
    var seen = -1;
    for (var i = 0; i < widget.signs.length; i++) {
      if (signVocabulary.containsKey(widget.signs[i])) seen++;
      if (seen == idx) return i;
    }
    return null;
  }

  void _play() {
    final web = _web;
    if (web == null || !_ready) return;
    final json = SignTimeline(widget.signs)
        .toJson(widget.signs, speed: widget.speed.clamp(0.2, 3));
    web.runJavaScript('window.avatar.play(${jsonEncode(json)})');
  }

  @override
  void didUpdateWidget(SignAvatarView old) {
    super.didUpdateWidget(old);
    if (old.playToken != widget.playToken ||
        old.speed != widget.speed ||
        !listEquals(old.signs, widget.signs)) {
      _play();
    }
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fallback = SignHandView(
      signs: widget.signs,
      playToken: widget.playToken,
      speed: widget.speed,
      onSignIndex: widget.onSignIndex,
    );
    if (_failed) return fallback;
    return Stack(
      children: [
        if (_web != null) Positioned.fill(child: WebViewWidget(controller: _web!)),
        // The 2D hands keep signing until the 3D model is ready.
        if (!_ready) Positioned.fill(child: fallback),
        if (!_ready)
          const Positioned(
            top: AppSpace.sm,
            right: AppSpace.lg,
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        if (_ready)
          Positioned(
            left: AppSpace.sm,
            bottom: 2,
            child: IgnorePointer(
              child: Text(avatarCredit,
                  style: AppText.micro.copyWith(
                      fontSize: 9, color: AppPalette.textTertiary)),
            ),
          ),
      ],
    );
  }
}
