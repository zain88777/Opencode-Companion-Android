import '../api/models.dart';

/// One saved OpenCode server.
///
/// The password is never stored here - it lives in the platform keystore under
/// `conn_password_<id>` (see [ConnectionStore]).
class ServerConnection {
  const ServerConnection({
    required this.id,
    required this.name,
    required this.url,
    this.username = 'opencode',
    this.api = ServerApi.v2,
    this.directory,
    this.serverVersion,
    this.lastUsed = 0,
  });

  final String id;
  final String name;

  /// Base URL without a trailing slash, e.g. http://100.64.0.1:4096.
  final String url;
  final String username;
  final ServerApi api;
  final String? directory;
  final String? serverVersion;

  /// Epoch millis of the last successful use, used for ordering.
  final int lastUsed;

  ServerConnection copyWith({
    String? name,
    String? url,
    String? username,
    ServerApi? api,
    String? directory,
    bool clearDirectory = false,
    String? serverVersion,
    int? lastUsed,
  }) =>
      ServerConnection(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        username: username ?? this.username,
        api: api ?? this.api,
        directory: clearDirectory ? null : (directory ?? this.directory),
        serverVersion: serverVersion ?? this.serverVersion,
        lastUsed: lastUsed ?? this.lastUsed,
      );

  /// Sanitises a user-entered URL: trims whitespace, drops a trailing slash,
  /// and adds http:// when no scheme was given.
  static String normalizeUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;
    if (!value.contains('://')) value = 'http://$value';
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'username': username,
        'api': api.name,
        if (directory != null) 'directory': directory,
        if (serverVersion != null) 'serverVersion': serverVersion,
        'lastUsed': lastUsed,
      };

  factory ServerConnection.fromJson(Map<String, dynamic> json) => ServerConnection(
        id: json['id'] as String,
        name: json['name'] as String? ?? json['url'] as String? ?? '',
        url: json['url'] as String? ?? '',
        username: json['username'] as String? ?? 'opencode',
        api: json['api'] == 'v1' ? ServerApi.v1 : ServerApi.v2,
        directory: json['directory'] as String?,
        serverVersion: json['serverVersion'] as String?,
        lastUsed: (json['lastUsed'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is ServerConnection && other.id == id;

  @override
  int get hashCode => id.hashCode;
}