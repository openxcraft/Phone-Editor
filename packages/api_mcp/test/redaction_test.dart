import 'package:api_mcp/api_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('Redactor', () {
    test('replaces every occurrence of a registered secret', () {
      final r = Redactor(sensitiveValues: <String>['sk-live-999']);
      final out = r.redact('auth sk-live-999 failed for sk-live-999');
      expect(out, 'auth [redacted] failed for [redacted]');
      expect(out, isNot(contains('sk-live-999')));
    });

    test('replaces prompt content registered as sensitive', () {
      final r = Redactor();
      r.registerSensitive('the user private draft text');
      final out = r.redact('sending: the user private draft text (done)');
      expect(out, isNot(contains('private draft')));
      expect(out, contains('[redacted]'));
    });

    test('longer overlapping values redact fully', () {
      final r = Redactor(sensitiveValues: <String>['abc', 'abcdef']);
      expect(r.redact('value abcdef end'), 'value [redacted] end');
    });

    test('empty sensitive values are ignored', () {
      final r = Redactor(sensitiveValues: <String>['']);
      expect(r.redact('unchanged'), 'unchanged');
    });

    test('promptSummary exposes length only', () {
      final s = Redactor.promptSummary('hello secret world');
      expect(s, isNot(contains('secret')));
      expect(s, contains('18 chars'));
    });
  });

  group('CallbackPermissionPolicy ask-once semantics', () {
    test('grant for a read tool is cached per session; writes always ask',
        () async {
      var asks = 0;
      final policy = CallbackPermissionPolicy((_) async {
        asks++;
        return true;
      });
      PermissionRequest req(String tool, PermissionFrequency f) =>
          PermissionRequest(sessionId: 's1', tool: tool, frequency: f);

      expect(
          await policy.isAllowed(
              req('doc.read', PermissionFrequency.askOncePerSession)),
          isTrue);
      expect(
          await policy.isAllowed(
              req('doc.read', PermissionFrequency.askOncePerSession)),
          isTrue);
      expect(asks, 1); // second read did not ask again

      expect(
          await policy.isAllowed(
              req('doc.apply_edit', PermissionFrequency.askEveryCall)),
          isTrue);
      expect(
          await policy.isAllowed(
              req('doc.apply_edit', PermissionFrequency.askEveryCall)),
          isTrue);
      expect(asks, 3); // every write asked
    });

    test('denials are not cached', () async {
      var asks = 0;
      final policy = CallbackPermissionPolicy((_) async {
        asks++;
        return false;
      });
      const request = PermissionRequest(
        sessionId: 's1',
        tool: 'doc.read',
        frequency: PermissionFrequency.askOncePerSession,
      );
      expect(await policy.isAllowed(request), isFalse);
      expect(await policy.isAllowed(request), isFalse);
      expect(asks, 2);
    });
  });
}
