import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where saved passwords live.
///
/// Abstracted so tests (and platforms without a keystore) can substitute a
/// fake without touching the platform channel.
abstract class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production store backed by the Android Keystore / iOS Keychain.
class KeystoreCredentialStore implements CredentialStore {
  KeystoreCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory store for tests and previews.
class InMemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}