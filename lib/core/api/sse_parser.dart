/// Server-Sent Events framing parser.
///
/// The OpenCode server sends `data: {json}\n\n` frames and `: heartbeat\n\n`
/// comment frames. A single frame can be split across any number of network
/// reads, so the parser buffers until it sees a blank-line terminator.
///
/// Pure and side-effect free apart from its own buffer, so it is unit tested
/// without a socket.
library;

class SseParser {
  String _buffer = '';

  /// Feed one decoded text chunk; returns every complete `data:` payload that
  /// finished inside this chunk.
  List<String> push(String chunk) {
    _buffer += chunk;
    // Normalise line endings so framing is uniform. JSON payloads escape their
    // own control characters, so a literal CR/LF inside a payload never occurs.
    _buffer = _buffer.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final out = <String>[];
    var index = _buffer.indexOf('\n\n');
    while (index >= 0) {
      final block = _buffer.substring(0, index);
      _buffer = _buffer.substring(index + 2);
      final data = _dataOf(block);
      if (data != null) out.add(data);
      index = _buffer.indexOf('\n\n');
    }
    return out;
  }

  /// Flush any trailing block (used when the stream closes cleanly).
  String? flush() {
    if (_buffer.isEmpty) return null;
    final data = _dataOf(_buffer);
    _buffer = '';
    return data;
  }

  void reset() => _buffer = '';

  /// Extract the joined `data:` value from one frame. Comment lines (`:`),
  /// `event:`/`id:`/`retry:` fields and blank lines are ignored; the `[DONE]`
  /// sentinel is dropped.
  String? _dataOf(String block) {
    final dataLines = <String>[];
    for (final line in block.split('\n')) {
      if (line.startsWith(':')) continue;
      if (line.startsWith('data:')) {
        var value = line.substring(5);
        if (value.startsWith(' ')) value = value.substring(1);
        dataLines.add(value);
      }
    }
    if (dataLines.isEmpty) return null;
    final joined = dataLines.join('\n');
    if (joined.isEmpty || joined == '[DONE]') return null;
    return joined;
  }
}