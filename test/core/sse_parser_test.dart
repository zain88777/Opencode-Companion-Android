import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_companion/core/api/sse_parser.dart';

void main() {
  late SseParser parser;

  setUp(() => parser = SseParser());

  test('parses a single data frame', () {
    final out = parser.push('data: {"type":"server.connected","data":{}}\n\n');
    expect(out, ['{"type":"server.connected","data":{}}']);
  });

  test('ignores heartbeat comment frames', () {
    expect(parser.push(': heartbeat\n\n'), isEmpty);
  });

  test('reassembles a frame split across chunks', () {
    const payload = '{"type":"session.text.delta","data":{"delta":"hello"}}';
    final first = parser.push('data: {"type":"session.text.delta","da');
    expect(first, isEmpty);
    final second = parser.push('ta":{"delta":"hello"}}\n\n');
    expect(second, [payload]);
  });

  test('returns several frames from one chunk and keeps the partial tail', () {
    const chunk = 'data: {"a":1}\n\ndata: {"b":2}\n\ndata: {"c":';
    final out = parser.push(chunk);
    expect(out, ['{"a":1}', '{"b":2}']);
    expect(parser.push('3}\n\n'), ['{"c":3}']);
  });

  test('handles CRLF framing', () {
    expect(parser.push('data: {"a":1}\r\n\r\n'), ['{"a":1}']);
  });

  test('drops the [DONE] sentinel and empty payloads', () {
    expect(parser.push('data: [DONE]\n\n'), isEmpty);
    expect(parser.push('data: \n\n'), isEmpty);
  });

  test('supports multi-line data frames joined with newlines', () {
    final out = parser.push('data: line1\ndata: line2\n\n');
    expect(out, ['line1\nline2']);
  });

  test('ignores event/id/retry fields', () {
    final out = parser.push('id: 1\nevent: message\ndata: {"a":1}\n\n');
    expect(out, ['{"a":1}']);
  });

  test('flush returns a trailing frame and clears the buffer', () {
    expect(parser.push('data: {"a":1}\n\n'), ['{"a":1}']);
    expect(parser.flush(), isNull);
    parser.push('data: {"b":2}\n');
    expect(parser.flush(), '{"b":2}');
    expect(parser.flush(), isNull);
  });

  test('reset clears a partial buffer', () {
    parser.push('data: {"a"');
    parser.reset();
    expect(parser.push('data: {"b":2}\n\n'), ['{"b":2}']);
  });
}