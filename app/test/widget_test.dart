import 'package:flutter_test/flutter_test.dart';
import 'package:opensms_gateway/main.dart';

void main() {
  group('GatewayConfig URL derivation', () {
    test('https base becomes wss with /ws and the device token', () {
      const config = GatewayConfig(
        serverUrl: 'https://sms.example.com',
        deviceToken: 'dt_abc',
      );

      final uri = config.wsUri!;
      expect(uri.scheme, 'wss');
      expect(uri.host, 'sms.example.com');
      expect(uri.path, '/ws');
      expect(uri.queryParameters['token'], 'dt_abc');
    });

    test('http base becomes ws and keeps the port', () {
      const config = GatewayConfig(
        serverUrl: 'http://192.168.1.10:3000',
        deviceToken: 'dt_local',
      );

      final uri = config.wsUri!;
      expect(uri.scheme, 'ws');
      expect(uri.port, 3000);
      expect(uri.path, '/ws');
    });

    test('a custom base path is preserved', () {
      const config = GatewayConfig(
        serverUrl: 'https://example.com/relay/',
        deviceToken: 'dt_abc',
      );

      expect(config.wsUri!.path, '/relay/ws');
    });

    test('an explicit /ws suffix is not duplicated', () {
      const config = GatewayConfig(
        serverUrl: 'wss://example.com/ws',
        deviceToken: 'dt_abc',
      );

      expect(config.wsUri!.path, '/ws');
    });

    test('scheme-less input defaults to TLS', () {
      const config = GatewayConfig(serverUrl: 'sms.example.com', deviceToken: 'dt_abc');

      expect(config.wsUri!.scheme, 'wss');
      expect(config.wsUri!.path, '/ws');
    });

    test('health URI never carries the token', () {
      const config = GatewayConfig(
        serverUrl: 'https://sms.example.com',
        deviceToken: 'dt_abc',
      );

      final uri = config.healthUri!;
      expect(uri.toString(), 'https://sms.example.com/health');
      expect(uri.queryParameters.containsKey('token'), isFalse);
    });

    test('incomplete configuration produces no socket URI', () {
      expect(const GatewayConfig().wsUri, isNull);
      expect(const GatewayConfig(serverUrl: 'https://sms.example.com').wsUri, isNull);
      expect(const GatewayConfig(serverUrl: '   ', deviceToken: 'dt').wsUri, isNull);
    });
  });

  group('LogEntry', () {
    test('formats a zero-padded timestamp', () {
      final entry = LogEntry(DateTime(2026, 1, 2, 3, 4, 5), LogKind.info, 'hello');
      expect(entry.timeLabel, '03:04:05');
    });
  });
}
