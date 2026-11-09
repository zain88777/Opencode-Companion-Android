/// Errors thrown by the OpenCode API client.
library;

/// A non-2xx response that is not an auth problem.
class ApiException implements Exception {
  ApiException(this.status, this.body)
      : message = 'API Error: $status - $body';

  final int status;
  final String body;
  final String message;

  bool get isNotFound => status == 404;
  bool get isConflict => status == 409;
  bool get isAuth => status == 401 || status == 403;

  @override
  String toString() => message;
}

/// 401/403 - credentials missing or rejected.
class ApiAuthException extends ApiException {
  ApiAuthException(super.status, super.body);

  @override
  String toString() => 'Authentication failed ($status). '
      'Check the server password for this connection.';
}

/// The endpoint answered, but it is not an OpenCode server API.
class UnsupportedServerException implements Exception {
  UnsupportedServerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The SSE stream produced no data within the idle window, or closed.
class EventStreamException implements Exception {
  EventStreamException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when a request exceeds its timeout.
class RequestTimeoutException implements Exception {
  RequestTimeoutException(this.durationMs);

  final int durationMs;

  @override
  String toString() => 'Request timed out after ${durationMs}ms';
}

/// Maps a raw HTTP status/body to the right ApiException subtype.
ApiException apiErrorFor(int status, String body) {
  if (status == 401 || status == 403) return ApiAuthException(status, body);
  return ApiException(status, body);
}