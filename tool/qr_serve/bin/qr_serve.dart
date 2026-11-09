// ignore_for_file: avoid_print
//
// Prints - and optionally renders to an image file - a scannable QR code the
// OpenCode mobile companion can pair from.
//
// Two modes:
//
//   pairing (default) - calls POST /api/pair on a running server and prints the
//                       official {"code","urls"} payload. The code is single-use
//                       and expires after five minutes.
//
//   password          - prints a payload carrying the server password, for a
//                       headless server that cannot reach /api/pair.
//
// Usage:
//   dart pub get
//   dart run bin/qr_serve.dart --url http://100.64.0.1:4096 --password secret
//   dart run bin/qr_serve.dart --image qr.bmp --url http://100.64.0.1:4096 --password secret
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:qr/qr.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('mode',
        abbr: 'm',
        defaultsTo: 'pairing',
        allowed: ['pairing', 'password'],
        help: 'pairing calls /api/pair; password prints the password directly')
    ..addOption('url',
        abbr: 'u',
        mandatory: true,
        help: 'Base URL of the OpenCode server, e.g. http://100.64.0.1:4096')
    ..addOption('password',
        abbr: 'p',
        mandatory: true,
        help: 'OPENCODE_SERVER_PASSWORD value')
    ..addOption('username',
        abbr: 'n',
        defaultsTo: 'opencode',
        help: 'OPENCODE_SERVER_USERNAME value (default: opencode)')
    ..addOption('name',
        abbr: 'l',
        help: 'Friendly label shown in the app')
    ..addOption('image',
        help: 'Also write the code as a 24-bit BMP at this path, for pointing a '
            'phone camera at the monitor')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help');

  final args = parser.parse(arguments);
  if (args['help'] as bool) {
    print(parser.usage);
    return;
  }

  final base = (args['url'] as String).replaceAll(RegExp(r'/+$'), '');
  final username = args['username'] as String;
  final password = args['password'] as String;

  final Map<String, dynamic> payload;
  if (args['mode'] == 'pairing') {
    final code = await _pairCode(base, username, password);
    payload = {'code': code, 'urls': [base]};
  } else {
    payload = {
      'v': 1,
      'url': base,
      'username': username,
      'password': password,
      if (args['name'] != null) 'name': args['name'],
    };
  }

  final json = jsonEncode(payload);
  final qr = QrCode.fromData(
    data: json,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final image = QrImage(qr);

  if (args['image'] != null) {
    final scale = 10;
    final quiet = 4;
    final size = (image.moduleCount + quiet * 2) * scale;
    final file = File(args['image'] as String);
    await file.writeAsBytes(_bmp(size, scale, quiet, image));
    print('Wrote ${file.path} (${size}x$size)');
  }

  const dark = '##';
  const light = '  ';
  final buffer = StringBuffer();
  buffer.writeln();
  for (var y = 0; y < image.moduleCount; y++) {
    buffer.write(light);
    for (var x = 0; x < image.moduleCount; x++) {
      buffer.write(image.isDark(y, x) ? dark : light);
    }
    buffer.writeln();
    buffer.write(light);
    for (var x = 0; x < image.moduleCount; x++) {
      buffer.write(image.isDark(y, x) ? dark : light);
    }
    buffer.writeln();
  }
  buffer.writeln();

  print(buffer);
  print('Server:   $base');
  print('Username: $username');
  print('Password: ${'*' * password.length}');
  print('Payload:  $json');
  print('');
  print('Scan this with the OpenCode app (Add server -> Scan QR).');
  if (args['mode'] == 'pairing') {
    print('Pairing codes are single-use and expire after five minutes.');
  } else {
    print('This QR carries the server password in plaintext - generate it only '
        'on a screen you control, and use a long random password.');
  }
}

/// Encodes a 24-bit uncompressed BMP. Chosen because it needs no codec and the
/// default Windows Photos app opens it.
List<int> _bmp(
  int size,
  int scale,
  int quiet,
  QrImage image,
) {
  final moduleCount = image.moduleCount;
  final rowBytes = (size * 3 + 3) & ~3;
  final pixelBytes = rowBytes * size;
  final fileSize = 54 + pixelBytes;
  final out = List<int>.filled(fileSize, 0);

  out[0] = 0x42; // 'B'
  out[1] = 0x4d; // 'M'
  _writeUint32(out, 2, fileSize);
  _writeUint32(out, 10, 54);
  _writeUint32(out, 14, 40);
  _writeUint32(out, 18, size);
  _writeUint32(out, 22, size);
  _writeUint16(out, 26, 1);
  _writeUint16(out, 28, 24);
  _writeUint32(out, 30, 0);
  _writeUint32(out, 34, pixelBytes);
  _writeUint32(out, 38, 2835);
  _writeUint32(out, 42, 2835);

  bool dark(int x, int y) {
    final mx = x ~/ scale - quiet;
    final my = y ~/ scale - quiet;
    if (mx < 0 || my < 0 || mx >= moduleCount || my >= moduleCount) return false;
    return image.isDark(my, mx);
  }

  for (var y = 0; y < size; y++) {
    final row = size - 1 - y; // BMP rows are bottom-up
    for (var x = 0; x < size; x++) {
      final isDark = dark(x, y);
      final offset = 54 + row * rowBytes + x * 3;
      out[offset] = isDark ? 0 : 255; // B
      out[offset + 1] = isDark ? 0 : 255; // G
      out[offset + 2] = isDark ? 0 : 255; // R
    }
  }
  return out;
}

void _writeUint16(List<int> out, int offset, int value) {
  out[offset] = value & 0xff;
  out[offset + 1] = (value >> 8) & 0xff;
}

void _writeUint32(List<int> out, int offset, int value) {
  out[offset] = value & 0xff;
  out[offset + 1] = (value >> 8) & 0xff;
  out[offset + 2] = (value >> 16) & 0xff;
  out[offset + 3] = (value >> 24) & 0xff;
}

/// Calls POST /api/pair and returns the one-time code.
Future<String> _pairCode(String base, String username, String password) async {
  final client = HttpClient();
  try {
    final request = await client
        .openUrl('POST', Uri.parse('$base/api/pair'))
        .timeout(const Duration(seconds: 8));
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('$username:$password'))}',
    );
    request.headers.contentType = ContentType.json;
    final response = await request.close().timeout(const Duration(seconds: 8));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw Exception('POST /api/pair failed with ${response.statusCode}: $body');
    }
    final decoded = jsonDecode(body);
    final code = decoded is Map ? decoded['code'] : null;
    if (code is! String || code.isEmpty) {
      throw Exception('POST /api/pair returned no code: $body');
    }
    return code;
  } finally {
    client.close(force: true);
  }
}