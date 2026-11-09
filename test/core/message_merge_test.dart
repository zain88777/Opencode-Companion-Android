import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_companion/core/api/models.dart';
import 'package:opencode_companion/core/chat/message_merge.dart';

Message _message(String id, String role) => Message(
      id: id,
      sessionID: 'ses_1',
      role: role,
      created: 0,
    );

void main() {
  test('an update to a known message replaces it in place', () {
    final before = [_message('msg_1', 'user')];
    final after = mergeIncomingMessage(
      before,
      _message('msg_1', 'user').copyWith(finish: 'stop'),
    );
    expect(after, hasLength(1));
    expect(after.single.finish, 'stop');
  });

  test('a real message resolves the oldest matching optimistic message', () {
    final before = [
      _message('temp-1', 'user'),
      _message('temp-2', 'user'),
    ];
    final after = mergeIncomingMessage(before, _message('msg_9', 'user'));
    expect(after, hasLength(2));
    expect(after[0].id, 'msg_9');
    expect(after[1].id, 'temp-2');
  });

  test('an assistant message does not resolve a pending user message', () {
    final before = [_message('temp-1', 'user')];
    final after = mergeIncomingMessage(before, _message('msg_9', 'assistant'));
    expect(after, hasLength(2));
    expect(after.last.id, 'msg_9');
  });

  test('a message with no placeholder to resolve is appended', () {
    final before = [_message('msg_1', 'user')];
    final after = mergeIncomingMessage(before, _message('msg_2', 'assistant'));
    expect(after.map((m) => m.id).toList(), ['msg_1', 'msg_2']);
  });

  test('parts are replaced by id, not appended', () {
    const part = Part(
      id: 'text-msg_1|0',
      messageID: 'msg_1',
      type: PartType.text,
      text: 'he',
    );
    final after = mergeIncomingPart([part], part.copyWith(text: 'hello'));
    expect(after, hasLength(1));
    expect(after.single.text, 'hello');
  });

  test('unknown parts are appended', () {
    const first = Part(id: 'a', messageID: 'msg_1', type: PartType.text, text: 'a');
    const second = Part(id: 'b', messageID: 'msg_1', type: PartType.text, text: 'b');
    expect(mergeIncomingPart([first], second).map((p) => p.id).toList(), ['a', 'b']);
  });

  test('dropPending removes only the matching role', () {
    final before = [
      _message('temp-1', 'user'),
      _message('msg_1', 'assistant'),
    ];
    final after = dropPending(before, 'user');
    expect(after.map((m) => m.id).toList(), ['msg_1']);
  });
}