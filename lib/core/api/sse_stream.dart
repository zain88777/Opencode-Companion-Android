import 'dart:async';
import 'dart:convert';

import 'errors.dart';
import 'sse_parser.dart';
import 'transport.dart';

/// A reconnecting SSE connection to the OpenCode event stream.
///
/// The server emits a `: heartbeat` comment every 15s, so any bytes on the wire
/// prove the connection is alive. [idleTimeout] of silence means the stream is
/// dead - the usual case after Android backgrounds or freezes the app, where the
/// socket goes half-open and `read()` hangs forever instead of reporting a
/// close. Without this watchdog the UI would sit showing "connected" with a
/// frozen stream until the next HTTP call happened to fail.
class EventStream {
  EventStream({
    required this.url,
    required this.headers,
    required this.transport,
    this.idleTimeout = const Duration(seconds: 45),
    this.maxBackoff = const Duration(seconds: 30),
    this.minBackoff = const Duration(seconds: 1),
  });

  final Uri url;
  final Map<String, String> headers;
  final HttpTransport transport;
  final Duration idleTimeout;
  final Duration maxBackoff;
  final Duration minBackoff;

  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Completes when [dispose] is called, so a blocked read cannot keep the
  /// isolate (or a test) alive.
  final Completer<void> _disposed = Completer<void>();

  StreamSubscription<String>? _subscription;
  Timer? _watchdog;
  Timer? _backoffTimer;
  bool _stopped = false;
  bool _started = false;

  int _consecutiveFailures = 0;

  /// Broadcast stream of decoded SSE event payloads.
  Stream<Map<String, dynamic>> get events => _controller.stream;

  /// Starts the connection loop. Safe to call once; subsequent calls are no-ops.
  void start() {
    if (_started || _stopped) return;
    _started = true;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_stopped) {
      final connectedAt = DateTime.now();
      try {
        await _consumeOnce();
        // A stream that stayed up for a while proves the connection is healthy;
        // reset the backoff so the next blip retries quickly.
        if (DateTime.now().difference(connectedAt) >
            const Duration(seconds: 10)) {
          _consecutiveFailures = 0;
        }
      } catch (e) {
        _consecutiveFailures++;
        if (!_controller.isClosed) {
          // Errors are surfaced to listeners; the loop keeps retrying.
          _controller.addError(e);
        }
      }
      if (_stopped) break;
      await _delayBeforeRetry();
    }
  }

  Future<void> _delayBeforeRetry() async {
    final factor = 1 << (_consecutiveFailures - 1).clamp(0, 5);
    final delay = Duration(
      milliseconds: (minBackoff.inMilliseconds * factor).clamp(
        minBackoff.inMilliseconds,
        maxBackoff.inMilliseconds,
      ),
    );
    final completer = Completer<void>();
    _backoffTimer = Timer(delay, () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    _backoffTimer = null;
  }

  Future<void> _consumeOnce() async {
    final response = await transport.openStream(url, headers);
    if (_stopped) return;
    if (!response.ok) {
      throw EventStreamException(
        'Event stream failed: HTTP ${response.status}',
      );
    }

    final parser = SseParser();
    final completer = Completer<void>();

    void armWatchdog() {
      _watchdog?.cancel();
      _watchdog = Timer(idleTimeout, () {
        if (!completer.isCompleted) {
          completer.completeError(
            EventStreamException(
              'Event stream idle - no heartbeat for ${idleTimeout.inSeconds}s',
            ),
          );
        }
      });
    }

    _subscription = response.stream.transform(utf8.decoder).listen(
      (chunk) {
        armWatchdog();
        for (final data in parser.push(chunk)) {
          try {
            final decoded = jsonDecode(data);
            if (decoded is Map<String, dynamic>) _controller.add(decoded);
          } catch (_) {
            // Malformed frame: skip rather than killing the stream.
          }
        }
      },
      onDone: () {
        _watchdog?.cancel();
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        _watchdog?.cancel();
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: false,
    );

    armWatchdog();
    try {
      await Future.any([completer.future, _disposed.future]);
    } finally {
      _watchdog?.cancel();
      await _subscription?.cancel();
      _subscription = null;
    }
  }

  /// Closes the stream permanently.
  ///
  /// Every await here is bounded: a half-open socket or a stuck listener must
  /// not be able to hang app shutdown.
  Future<void> dispose() async {
    _stopped = true;
    _watchdog?.cancel();
    _backoffTimer?.cancel();
    if (!_disposed.isCompleted) _disposed.complete();

    final subscription = _subscription;
    _subscription = null;
    try {
      await subscription?.cancel().timeout(const Duration(seconds: 2));
    } catch (_) {}

    if (!_controller.isClosed) {
      try {
        await _controller.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
  }
}