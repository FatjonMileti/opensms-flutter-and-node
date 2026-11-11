// ============================================================================
// OpenSMS Gateway — Android SMS relay client
// ============================================================================
// Single-screen app that:
//   1. Stores the relay server URL + device token.
//   2. Opens a persistent WebSocket to the server and keeps it alive.
//   3. Sends every `sms` frame silently through the device SIM (SmsManager).
//   4. Reports { id, status: Sent|Failed } back, buffering reports while offline.
//
// Layering: GatewayConfig (pure data) -> GatewayController (state machine) ->
// widgets. The controller has no Flutter widget dependencies, so it can be
// moved to its own file/service without changes.
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native bridge implemented in MainActivity.kt.
const MethodChannel _platform = MethodChannel('opensms/gateway');

const String _prefServerUrl = 'gateway.serverUrl';
const String _prefDeviceToken = 'gateway.deviceToken';
const String _prefAutoStart = 'gateway.autoStart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenSmsApp());
}

// ============================================================================
// Configuration model
// ============================================================================

@immutable
class GatewayConfig {
  const GatewayConfig({this.serverUrl = '', this.deviceToken = ''});

  final String serverUrl;
  final String deviceToken;

  bool get isComplete => serverUrl.trim().isNotEmpty && deviceToken.trim().isNotEmpty;

  /// `https://host:3000` -> `wss://host:3000/ws?token=...`
  /// `http://10.0.2.2:3000/relay` -> `ws://10.0.2.2:3000/relay/ws?token=...`
  Uri? get wsUri => _derive(secureScheme: 'wss', insecureScheme: 'ws', suffix: '/ws', withToken: true);

  /// `https://host:3000` -> `https://host:3000/health`
  Uri? get healthUri =>
      _derive(secureScheme: 'https', insecureScheme: 'http', suffix: '/health', withToken: false);

  Uri? _derive({
    required String secureScheme,
    required String insecureScheme,
    required String suffix,
    required bool withToken,
  }) {
    final raw = serverUrl.trim();
    if (raw.isEmpty) return null;
    if (withToken && deviceToken.trim().isEmpty) return null;

    Uri parsed;
    try {
      parsed = Uri.parse(raw.contains('://') ? raw : 'https://$raw');
    } on FormatException {
      return null;
    }
    if (parsed.host.isEmpty) return null;

    final secure = parsed.scheme == 'https' || parsed.scheme == 'wss';
    var path = parsed.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.endsWith(suffix)) path = '$path$suffix';

    final query = Map<String, String>.from(parsed.queryParameters);
    if (withToken) query['token'] = deviceToken.trim();

    return parsed.replace(
      scheme: secure ? secureScheme : insecureScheme,
      path: path,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  GatewayConfig copyWith({String? serverUrl, String? deviceToken}) => GatewayConfig(
        serverUrl: serverUrl ?? this.serverUrl,
        deviceToken: deviceToken ?? this.deviceToken,
      );
}

// ============================================================================
// Activity log + job models
// ============================================================================

enum LogKind { info, success, warning, error }

@immutable
class LogEntry {
  const LogEntry(this.at, this.kind, this.message);

  final DateTime at;
  final LogKind kind;
  final String message;

  String get timeLabel {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    final s = at.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

@immutable
class _OutboundSms {
  const _OutboundSms({
    required this.id,
    required this.to,
    required this.message,
    required this.attempt,
  });

  final String id;
  final String to;
  final String message;
  final int attempt;
}

enum GatewayStatus { stopped, connecting, connected, reconnecting, error }

extension _GatewayStatusUi on GatewayStatus {
  String get label => switch (this) {
        GatewayStatus.stopped => 'Stopped',
        GatewayStatus.connecting => 'Connecting',
        GatewayStatus.connected => 'Connected',
        GatewayStatus.reconnecting => 'Reconnecting',
        GatewayStatus.error => 'Error',
      };

  Color get color => switch (this) {
        GatewayStatus.stopped => const Color(0xFF94A3B8),
        GatewayStatus.connecting => const Color(0xFF38BDF8),
        GatewayStatus.connected => const Color(0xFF34D399),
        GatewayStatus.reconnecting => const Color(0xFFFBBF24),
        GatewayStatus.error => const Color(0xFFF87171),
      };
}

// ============================================================================
// Gateway controller — connection state machine + SMS execution
// ============================================================================

class GatewayController extends ChangeNotifier {
  final List<LogEntry> _logs = <LogEntry>[];
  final List<_OutboundSms> _queue = <_OutboundSms>[];
  final List<Map<String, Object?>> _pendingReports = <Map<String, Object?>>[];
  final Set<String> _seenIds = <String>{};
  final Random _random = Random();

  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;

  GatewayConfig _config = const GatewayConfig();
  GatewayStatus _status = GatewayStatus.stopped;
  DateTime _lastPong = DateTime.now();
  DateTime? _connectedSince;

  bool _enabled = false;
  bool _initialized = false;
  bool _disposed = false;
  bool _sending = false;
  bool _connecting = false;
  bool _dropping = false;
  int _reconnectAttempt = 0;
  int _sentCount = 0;
  int _failedCount = 0;
  String? _deviceId;
  String? _lastError;
  String _carrier = '';
  bool _batteryOptimized = true;

  GatewayConfig get config => _config;
  GatewayStatus get status => _status;
  bool get enabled => _enabled;
  bool get initialized => _initialized;
  List<LogEntry> get logs => List<LogEntry>.unmodifiable(_logs);
  int get sentCount => _sentCount;
  int get failedCount => _failedCount;
  int get queuedCount => _queue.length;
  String? get deviceId => _deviceId;
  String? get lastError => _lastError;
  String get carrier => _carrier;
  bool get batteryOptimized => _batteryOptimized;
  DateTime? get connectedSince => _connectedSince;

  bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  // ---------------------------------------------------------------- lifecycle

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _config = GatewayConfig(
      serverUrl: prefs.getString(_prefServerUrl) ?? '',
      deviceToken: prefs.getString(_prefDeviceToken) ?? '',
    );
    _initialized = true;
    _notify();

    await _refreshBatteryState();
    await _loadCarrier();

    final autoStart = prefs.getBool(_prefAutoStart) ?? false;
    if (autoStart && _config.isComplete) {
      _log(LogKind.info, 'Auto-starting gateway from the previous session.');
      // Give the platform activity a moment to attach before asking for
      // runtime permissions.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!_disposed && !_enabled) await start();
    }
  }

  Future<void> saveConfig(GatewayConfig next) async {
    _config = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefServerUrl, next.serverUrl.trim());
    await prefs.setString(_prefDeviceToken, next.deviceToken.trim());
    _notify();
  }

  Future<void> start() async {
    if (_enabled) return;

    if (!_config.isComplete || _config.wsUri == null) {
      _lastError = 'Enter a valid server URL and device token first.';
      _log(LogKind.error, _lastError!);
      _notify();
      return;
    }

    _lastError = null;
    _status = GatewayStatus.connecting;
    _notify();

    if (isAndroid) {
      final granted = await _requestPermissions();
      if (!granted) {
        _status = GatewayStatus.error;
        _lastError = 'SMS permission was not granted.';
        _notify();
        return;
      }
      await _startForegroundService();
      await _loadCarrier();
      await _refreshBatteryState();
    }

    _enabled = true;
    _reconnectAttempt = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefAutoStart, true);
    _notify();

    await _connect();
  }

  Future<void> stop({String? reason}) async {
    final wasEnabled = _enabled;
    _enabled = false;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _queue.clear();
    _pendingReports.clear();
    await _teardownSocket();

    _status = GatewayStatus.stopped;
    _connectedSince = null;
    if (reason != null) {
      _log(LogKind.warning, reason);
    } else if (wasEnabled) {
      _log(LogKind.info, 'Gateway stopped.');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefAutoStart, false);
    await _stopForegroundService();
    _notify();
  }

  void reconnectNow() {
    if (!_enabled) return;
    _reconnectAttempt = 0;
    _log(LogKind.info, 'Manual reconnect requested.');
    unawaited(_connect());
  }

  void clearLogs() {
    _logs.clear();
    _notify();
  }

  // ------------------------------------------------------------- connection

  Future<void> _connect() async {
    if (!_enabled || _disposed || _connecting) return;

    final uri = _config.wsUri;
    if (uri == null) {
      _failPermanently('The server URL is not valid.');
      return;
    }

    _connecting = true;
    try {
      _reconnectTimer?.cancel();
      await _teardownSocket();
      if (!_enabled || _disposed) return;

      _status = _reconnectAttempt == 0 ? GatewayStatus.connecting : GatewayStatus.reconnecting;
      _notify();
      _log(LogKind.info, 'Connecting to ${uri.host}:${uri.port}${uri.path}…');

      final WebSocketChannel socket;
      try {
        socket = WebSocketChannel.connect(uri);
        _socket = socket;
        await socket.ready.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        await _handleDrop('Handshake timed out after 15s.');
        return;
      } catch (error) {
        await _handleDrop('Connection failed: $error');
        return;
      }

      // The user may have stopped the gateway while the handshake was in flight.
      if (!_enabled || _disposed || _socket != socket) {
        try {
          await socket.sink.close();
        } catch (_) {
          // ignore
        }
        return;
      }

      _reconnectAttempt = 0;
      _lastPong = DateTime.now();
      _connectedSince = DateTime.now();
      _status = GatewayStatus.connected;
      _lastError = null;
      _log(LogKind.success, 'Connected. Waiting for SMS jobs.');
      _notify();

      _socketSub = socket.stream.listen(
        _handleFrame,
        onError: (Object error) => unawaited(_handleDrop('Socket error: $error')),
        onDone: () => unawaited(_handleDrop('The server closed the connection.')),
        cancelOnError: true,
      );

      _startHeartbeat();
      await _flushPendingReports();
    } finally {
      _connecting = false;
    }
  }

  Future<void> _handleDrop(String reason) async {
    if (_disposed || _dropping) return;
    _dropping = true;
    try {
      _heartbeatTimer?.cancel();
      await _teardownSocket();

      if (!_enabled) {
        _status = GatewayStatus.stopped;
        _notify();
        return;
      }

      _lastError = reason;
      _log(LogKind.warning, reason);
      _scheduleReconnect();
    } finally {
      _dropping = false;
    }
  }

  void _scheduleReconnect() {
    if (!_enabled || _disposed) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt += 1;

    final exponent = min(_reconnectAttempt - 1, 5);
    final backoffMs = min(30000, 1000 * pow(2, exponent).toInt());
    final delay = Duration(milliseconds: backoffMs + _random.nextInt(750));

    _status = GatewayStatus.reconnecting;
    _log(
      LogKind.info,
      'Retrying in ${(delay.inMilliseconds / 1000).toStringAsFixed(1)}s '
      '(attempt $_reconnectAttempt).',
    );
    _notify();

    _reconnectTimer = Timer(delay, () => unawaited(_connect()));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPong = DateTime.now();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!_enabled || _status != GatewayStatus.connected) return;
      if (DateTime.now().difference(_lastPong) > const Duration(seconds: 60)) {
        unawaited(_handleDrop('Heartbeat timed out — no pong from the server.'));
        return;
      }
      _send(<String, Object?>{
        'type': 'ping',
        'ts': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<void> _teardownSocket() async {
    final sub = _socketSub;
    final socket = _socket;
    _socketSub = null;
    _socket = null;

    await sub?.cancel();
    if (socket != null) {
      try {
        await socket.sink.close(1000, 'client closing');
      } catch (_) {
        // socket already gone
      }
    }
  }

  bool _send(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null || _status != GatewayStatus.connected) return false;
    try {
      socket.sink.add(jsonEncode(frame));
      return true;
    } catch (error) {
      _log(LogKind.warning, 'Could not write to the socket: $error');
      return false;
    }
  }

  // -------------------------------------------------------------- inbound

  void _handleFrame(dynamic raw) {
    if (raw is! String) return;

    Map<String, dynamic> frame;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('frame is not a JSON object');
      }
      frame = decoded;
    } on FormatException {
      _log(LogKind.warning, 'Ignored a malformed frame from the server.');
      return;
    }

    switch (frame['type']) {
      case 'welcome':
        _deviceId = frame['deviceId'] as String?;
        _lastPong = DateTime.now();
        _log(
          LogKind.info,
          'Authenticated as ${_deviceId ?? 'gateway'}; '
          'server queue ${frame['pending'] ?? 0}.',
        );
        _notify();
      case 'pong':
        _lastPong = DateTime.now();
      case 'sms':
        _enqueueJob(frame);
      case 'ack':
        break;
      case 'auth_error':
        final reason = frame['reason'] ?? 'unknown';
        unawaited(_handleAuthError('The server rejected this device token ($reason).'));
      case 'server_shutdown':
        _log(LogKind.warning, 'Server is restarting — reconnecting shortly.');
      case 'error':
        _log(
          LogKind.warning,
          'Server: ${frame['message'] ?? frame['code'] ?? 'unknown error'}',
        );
      default:
        break;
    }
  }

  void _enqueueJob(Map<String, dynamic> frame) {
    final id = frame['id']?.toString() ?? '';
    final to = frame['to']?.toString() ?? '';
    final message = frame['message']?.toString() ?? '';

    if (id.isEmpty || to.isEmpty || message.isEmpty) {
      _log(LogKind.error, 'Received an incomplete SMS job; ignoring it.');
      return;
    }
    if (_seenIds.contains(id)) {
      _log(LogKind.warning, 'Duplicate job $id ignored.');
      return;
    }

    _seenIds.add(id);
    if (_seenIds.length > 500) _seenIds.remove(_seenIds.first);

    _queue.add(
      _OutboundSms(
        id: id,
        to: to,
        message: message,
        attempt: (frame['attempt'] as num?)?.toInt() ?? 1,
      ),
    );
    _log(LogKind.info, 'Job $id → $to (${message.length} chars) queued.');
    _notify();
    unawaited(_drainQueue());
  }

  // -------------------------------------------------------------- outbound

  Future<void> _drainQueue() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_queue.isNotEmpty && _enabled) {
        final job = _queue.removeAt(0);
        _notify();

        final started = DateTime.now();
        var outcome = 'Failed';
        String? error;

        try {
          final result = await _platform
              .invokeMethod<String>('sendSms', <String, Object?>{
                'id': job.id,
                'to': job.to,
                'message': job.message,
              })
              .timeout(const Duration(seconds: 120));
          outcome = result == 'Sent' ? 'Sent' : 'Failed';
          if (outcome == 'Failed') {
            error = 'The device could not hand the SMS to the network.';
          }
        } on PlatformException catch (exception) {
          error = exception.message ?? exception.code;
        } on TimeoutException {
          error = 'Sending timed out after 120s.';
        } on MissingPluginException {
          error = 'SMS bridge unavailable (not running on Android?).';
        } catch (exception) {
          error = exception.toString();
        }

        final elapsed = DateTime.now().difference(started).inMilliseconds;
        if (outcome == 'Sent') {
          _sentCount += 1;
          _log(LogKind.success, 'Sent SMS ${job.id} to ${job.to} in ${elapsed}ms.');
        } else {
          _failedCount += 1;
          _lastError = error;
          _log(LogKind.error, 'Failed SMS ${job.id} to ${job.to}: ${error ?? 'unknown error'}');
        }

        _reportStatus(job.id, outcome, error);
        _notify();
      }
    } finally {
      _sending = false;
      _notify();
    }
  }

  void _reportStatus(String id, String status, String? error) {
    final report = <String, Object?>{
      'type': 'status_update',
      'id': id,
      'status': status,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
    };
    if (error != null) report['error'] = error;

    if (!_send(report)) {
      _pendingReports.add(report);
      if (_pendingReports.length > 100) _pendingReports.removeAt(0);
      _log(LogKind.warning, 'Offline — status for $id buffered for the next connection.');
    }
  }

  Future<void> _flushPendingReports() async {
    while (_pendingReports.isNotEmpty && _status == GatewayStatus.connected) {
      final report = _pendingReports.first;
      if (!_send(report)) break;
      _pendingReports.removeAt(0);
      _log(LogKind.info, 'Replayed buffered status for ${report['id']}.');
    }
  }

  Future<void> _handleAuthError(String reason) async {
    _enabled = false;
    _status = GatewayStatus.error;
    _lastError = reason;
    _log(LogKind.error, reason);
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    await _teardownSocket();
    await _stopForegroundService();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefAutoStart, false);
    _notify();
  }

  void _failPermanently(String reason) {
    _enabled = false;
    _status = GatewayStatus.error;
    _lastError = reason;
    _log(LogKind.error, reason);
    _notify();
  }

  // ------------------------------------------------------------ permissions

  Future<bool> _requestPermissions() async {
    final results = await <Permission>[
      Permission.sms, // SEND_SMS + RECEIVE_SMS (READ_SMS is not requested)
      Permission.phone, // READ_PHONE_STATE, used for the carrier label
      Permission.notification,
    ].request();

    final sms = results[Permission.sms];
    final phone = results[Permission.phone];
    final notifications = results[Permission.notification];

    if (sms != PermissionStatus.granted) {
      _log(LogKind.error, 'SMS permission denied (${sms ?? 'unknown'}).');
      return false;
    }
    if (phone != PermissionStatus.granted) {
      _log(LogKind.warning, 'Phone-state permission denied — carrier name hidden.');
    }
    if (notifications != null && (notifications.isDenied || notifications.isPermanentlyDenied)) {
      _log(LogKind.warning, 'Notifications denied — the foreground notice may be hidden.');
    }
    return true;
  }

  Future<void> _startForegroundService() async {
    if (!isAndroid) return;
    try {
      await _platform.invokeMethod<bool>('startForegroundService', <String, Object?>{
        'text': 'Connected to ${_config.wsUri?.host ?? 'your server'}',
      });
    } on MissingPluginException {
      // Desktop/web builds have no native bridge.
    } catch (error) {
      _log(LogKind.warning, 'Could not start the foreground service: $error');
    }
  }

  Future<void> _stopForegroundService() async {
    if (!isAndroid) return;
    try {
      await _platform.invokeMethod<bool>('stopForegroundService');
    } catch (_) {
      // Nothing to stop.
    }
  }

  Future<void> _refreshBatteryState() async {
    if (!isAndroid) return;
    try {
      final ignoring =
          await _platform.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
      _batteryOptimized = ignoring;
      _notify();
    } catch (_) {
      // Older/unsupported devices.
    }
  }

  Future<void> requestBatteryExemption() async {
    if (!isAndroid) return;
    try {
      final opened =
          await _platform.invokeMethod<bool>('requestIgnoreBatteryOptimizations') ?? false;
      if (opened) _log(LogKind.info, 'Battery-optimisation settings opened.');
      await _refreshBatteryState();
    } catch (error) {
      _log(LogKind.warning, 'Could not open battery settings: $error');
    }
  }

  Future<void> _loadCarrier() async {
    if (!isAndroid) return;
    try {
      final info = await _platform.invokeMapMethod<String, dynamic>('simInfo');
      final carrier = info?['carrier'] as String?;
      final simState = info?['simState'] as String?;
      if (carrier != null && carrier.isNotEmpty) {
        _carrier = simState == null || simState == 'ready' ? carrier : '$carrier ($simState)';
        _notify();
      }
    } catch (_) {
      // Permission not granted yet, or no telephony service.
    }
  }

  // ------------------------------------------------------------------ misc

  Future<bool> probeServer() async {
    final uri = _config.healthUri;
    if (uri == null) {
      _log(LogKind.error, 'Enter a valid server URL before testing.');
      return false;
    }

    _log(LogKind.info, 'Probing $uri');
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        _log(LogKind.error, 'Health check failed with HTTP ${response.statusCode}.');
        return false;
      }
      final body = jsonDecode(response.body);
      final details = body is Map<String, dynamic>
          ? 'v${body['version']}, devices ${body['devicesOnline']}, queue ${body['queueDepth']}'
          : 'no details';
      _log(LogKind.success, 'Server reachable — $details.');
      return true;
    } on TimeoutException {
      _log(LogKind.error, 'Health check timed out after 10s.');
    } catch (error) {
      _log(LogKind.error, 'Health check failed: $error');
    }
    return false;
  }

  void _log(LogKind kind, String message) {
    _logs.add(LogEntry(DateTime.now(), kind, message));
    if (_logs.length > 200) _logs.removeRange(0, _logs.length - 200);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _socketSub?.cancel();
    _socket?.sink.close();
    super.dispose();
  }
}

// ============================================================================
// App shell
// ============================================================================

class OpenSmsApp extends StatefulWidget {
  const OpenSmsApp({super.key});

  @override
  State<OpenSmsApp> createState() => _OpenSmsAppState();
}

class _OpenSmsAppState extends State<OpenSmsApp> {
  late final GatewayController _controller;

  @override
  void initState() {
    super.initState();
    _controller = GatewayController();
    unawaited(_controller.init());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF14B8A6);

    return MaterialApp(
      title: 'OpenSMS Gateway',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0B1115),
      ),
      home: GatewayHomePage(controller: _controller),
    );
  }
}

// ============================================================================
// Single-screen UI
// ============================================================================

class GatewayHomePage extends StatefulWidget {
  const GatewayHomePage({super.key, required this.controller});

  final GatewayController controller;

  @override
  State<GatewayHomePage> createState() => _GatewayHomePageState();
}

class _GatewayHomePageState extends State<GatewayHomePage> with WidgetsBindingObserver {
  late final TextEditingController _urlField;
  late final TextEditingController _tokenField;

  bool _obscureToken = true;
  bool _busy = false;
  bool _hydrated = false;

  GatewayController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _urlField = TextEditingController(text: _c.config.serverUrl);
    _tokenField = TextEditingController(text: _c.config.deviceToken);
    _c.addListener(_syncConfig);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_syncConfig);
    _urlField.dispose();
    _tokenField.dispose();
    super.dispose();
  }

  void _syncConfig() {
    if (_hydrated || !_c.initialized) return;
    _hydrated = true;
    _urlField.text = _c.config.serverUrl;
    _tokenField.text = _c.config.deviceToken;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _c.enabled &&
        _c.status != GatewayStatus.connected &&
        _c.status != GatewayStatus.connecting) {
      _c.reconnectNow();
    }
  }

  Future<bool> _validateAndSave() async {
    final config = GatewayConfig(
      serverUrl: _urlField.text.trim(),
      deviceToken: _tokenField.text.trim(),
    );
    if (!config.isComplete || config.wsUri == null) {
      _snack('Enter a valid server URL (e.g. https://sms.example.com) and the device token.');
      return false;
    }
    await _c.saveConfig(config);
    return true;
  }

  Future<void> _toggle(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (value) {
        if (!await _validateAndSave()) return;
        await _c.start();
      } else {
        await _c.stop();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testServer() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!await _validateAndSave()) return;
      final ok = await _c.probeServer();
      _snack(ok ? 'Server reachable.' : 'Server check failed — see the activity log.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveOnly() async {
    if (await _validateAndSave()) _snack('Configuration saved.');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            titleSpacing: 20,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'OpenSMS Gateway',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                Text(
                  'Android SMS relay',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              IconButton(
                tooltip: 'Reconnect now',
                onPressed: _c.enabled ? _c.reconnectNow : null,
                icon: const Icon(Icons.sync),
              ),
              IconButton(
                tooltip: 'Clear activity log',
                onPressed: _c.clearLogs,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: <Widget>[
                _configPanel(theme),
                const SizedBox(height: 14),
                _controlPanel(theme),
                const SizedBox(height: 14),
                _logPanel(theme),
                const SizedBox(height: 20),
                _footer(theme),
              ],
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ panels

  Widget _configPanel(ThemeData theme) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SectionTitle(icon: Icons.dns_outlined, title: 'Server connection'),
          const SizedBox(height: 14),
          TextField(
            controller: _urlField,
            enabled: !_c.enabled,
            autocorrect: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: _fieldDecoration(
              label: 'Express server URL',
              hint: 'https://sms.example.com',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenField,
            enabled: !_c.enabled,
            autocorrect: false,
            obscureText: _obscureToken,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            decoration: _fieldDecoration(
              label: 'Device token',
              hint: 'dt_…',
            ).copyWith(
              suffixIcon: IconButton(
                tooltip: _obscureToken ? 'Show token' : 'Hide token',
                onPressed: () => setState(() => _obscureToken = !_obscureToken),
                icon: Icon(
                  _obscureToken ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The WebSocket URL is derived automatically (ws:// or wss://) and '
            'the token is sent as a query parameter over TLS.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              TextButton.icon(
                onPressed: _busy || _c.enabled ? null : _testServer,
                icon: const Icon(Icons.network_check, size: 18),
                label: const Text('Test server'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy || _c.enabled ? null : _saveOnly,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlPanel(ThemeData theme) {
    final scheme = theme.colorScheme;
    final showMetrics = _c.enabled || _c.sentCount > 0 || _c.failedCount > 0;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _StatusPill(status: _c.status),
              const Spacer(),
              if (_c.deviceId != null)
                Flexible(
                  child: Text(
                    _c.deviceId!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _c.enabled,
            onChanged: _busy ? null : _toggle,
            title: const Text(
              'Gateway service',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _busy
                  ? 'Working…'
                  : _c.enabled
                      ? 'Relaying SMS from your server'
                      : 'Stopped — not connected to the server',
            ),
            secondary: Icon(
              _c.enabled ? Icons.play_circle_fill : Icons.power_settings_new,
              color: _c.enabled ? const Color(0xFF34D399) : scheme.onSurfaceVariant,
            ),
          ),
          if (showMetrics) ...<Widget>[
            Divider(height: 24, color: scheme.outlineVariant.withValues(alpha: 0.3)),
            Wrap(
              spacing: 18,
              runSpacing: 12,
              children: <Widget>[
                _Metric(label: 'Sent', value: '${_c.sentCount}', color: const Color(0xFF34D399)),
                _Metric(label: 'Failed', value: '${_c.failedCount}', color: const Color(0xFFF87171)),
                _Metric(label: 'Queued', value: '${_c.queuedCount}', color: const Color(0xFFFBBF24)),
                _Metric(
                  label: 'Carrier',
                  value: _c.carrier.isEmpty ? '—' : _c.carrier,
                  color: const Color(0xFF38BDF8),
                  width: 110,
                ),
              ],
            ),
          ],
          if (_c.lastError != null) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline, size: 16, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _c.lastError!,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
          if (_c.isAndroid) ...<Widget>[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _c.requestBatteryExemption,
                icon: Icon(
                  _c.batteryOptimized ? Icons.battery_saver : Icons.battery_charging_full,
                  size: 18,
                ),
                label: Text(
                  _c.batteryOptimized
                      ? 'Allow background operation'
                      : 'Battery optimisation disabled',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _logPanel(ThemeData theme) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SectionTitle(
            icon: Icons.receipt_long_outlined,
            title: 'Activity log',
            trailing: Text(
              '${_c.logs.length}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (_c.logs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'No activity yet. Add the server URL and device token, then switch '
                'the gateway on.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            )
          else
            ..._c.logs.reversed.map((LogEntry entry) => _LogRow(entry: entry)),
        ],
      ),
    );
  }

  Widget _footer(ThemeData theme) {
    return Text(
      'Messages are sent from this device\'s SIM card. Keep the gateway running '
      'and the app installed; Android may need the battery exemption above for '
      'reliable delivery while the screen is off.',
      textAlign: TextAlign.center,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
        height: 1.45,
      ),
    );
  }

  InputDecoration _fieldDecoration({required String label, required String hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.04),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF2DD4BF), width: 1.4),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }
}

// ============================================================================
// Small presentational widgets
// ============================================================================

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        trailing ?? const SizedBox.shrink(),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final GatewayStatus status;

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            status.label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
    this.width = 76,
  });

  final String label;
  final String value;
  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (IconData icon, Color color) = switch (entry.kind) {
      LogKind.info => (Icons.info_outline, scheme.primary),
      LogKind.success => (Icons.check_circle_outline, const Color(0xFF34D399)),
      LogKind.warning => (Icons.warning_amber_outlined, const Color(0xFFFBBF24)),
      LogKind.error => (Icons.error_outline, const Color(0xFFF87171)),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.message,
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            entry.timeLabel,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
