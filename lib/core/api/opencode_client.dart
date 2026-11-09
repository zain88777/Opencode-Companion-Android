import '../events/server_event.dart';
import 'client_config.dart';
import 'models.dart';

/// A prompt file attachment.
class PromptFile {
  const PromptFile({required this.uri, this.name, this.mime});

  final String uri;
  final String? name;
  final String? mime;

  Map<String, dynamic> toJson() => {
        'uri': uri,
        if (name != null) 'name': name,
        if (mime != null) 'mime': mime,
      };
}

/// Transport-agnostic surface of one OpenCode server.
///
/// Implementations differ in routing prefix, list envelopes and SSE payload
/// names; callers only see these shapes.
abstract class OpencodeClient {
  OpencodeClient(this.config);

  final ClientConfig config;

  /// Live, typed event stream. Reconnects on its own.
  Stream<ServerEvent> get events;

  Future<HealthInfo> health();

  // -- sessions -------------------------------------------------------------

  Future<List<Session>> listSessions();
  Future<Session?> getSession(String sessionID);
  Future<Session> createSession({String? title});
  Future<void> deleteSession(String sessionID);
  Future<Session> renameSession(String sessionID, String title);

  Future<List<MessageWithParts>> messages(String sessionID, {int? limit});
  Future<void> prompt(
    String sessionID, {
    required String text,
    List<PromptFile> files = const [],
    ModelRef? model,
    String? agent,
  });
  Future<void> runCommand(String sessionID, String command, {String? args});
  Future<bool> interrupt(String sessionID);

  Future<List<DiffEntry>> diff(String sessionID);
  Future<List<DiffEntry>> vcsDiff({String mode = 'working'});
  Future<bool> revert(String sessionID, String messageID);
  Future<bool> unrevert(String sessionID);

  // -- approvals ------------------------------------------------------------

  Future<List<PermissionRequest>> permissions({String? sessionID});
  Future<bool> replyPermission(
    String sessionID,
    String requestID,
    String decision,
  );

  Future<List<QuestionRequest>> questions({String? sessionID});
  Future<bool> replyQuestion(
    String sessionID,
    String requestID,
    Map<String, dynamic> answers,
  );
  Future<bool> rejectQuestion(String sessionID, String requestID);

  // -- catalog --------------------------------------------------------------

  Future<List<AgentInfo>> agents();
  Future<List<CommandInfo>> commands();
  Future<ProviderCatalog> providerCatalog();
  Future<void> selectModel(String sessionID, ModelRef model);
  Future<void> selectAgent(String sessionID, String agent);

  // -- filesystem -----------------------------------------------------------

  Future<List<FileEntry>> listFiles({String path = '.'});
  Future<FileContent?> readFile(String path);
  Future<LocationInfo> location();

  Future<void> dispose();
}