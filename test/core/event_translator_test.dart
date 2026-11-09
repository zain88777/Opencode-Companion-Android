import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_companion/core/api/models.dart';
import 'package:opencode_companion/core/events/event_translator.dart';
import 'package:opencode_companion/core/events/server_event.dart';

/// Payloads below are verbatim from a live opencode v2.2.6 event stream.
Map<String, dynamic> _event(String body) =>
    jsonDecode(body) as Map<String, dynamic>;

/// Builds an event payload as a Dart map, avoiding nested-JSON escaping.
Map<String, dynamic> _mapEvent(String type, Map<String, dynamic> data) =>
    {'type': type, 'created': 1, 'data': data};

void main() {
  late EventTranslator translator;

  setUp(() => translator = EventTranslator());

  test('server.connected produces no events', () {
    expect(
      translator.translate(_event(
        '{"id":"evt_1","type":"server.connected","data":{}}',
      )),
      isEmpty,
    );
  });

  test('inbox enqueued becomes a user message plus text part', () {
    final events = translator.translate(_event(
      '{"id":"evt_2","created":1794172471256,"type":"session.inbox.enqueued",'
      '"data":{"inboxID":"msg_1","sessionID":"ses_1",'
      '"item":{"type":"user","payload":{"text":"hello"},"delivery":"steer"}}}',
    ));

    expect(events, hasLength(2));
    final message = events[0] as MessageUpdatedEvent;
    expect(message.info.id, 'msg_1');
    expect(message.info.role, 'user');
    final part = events[1] as MessagePartUpdatedEvent;
    expect(part.part.text, 'hello');
    expect(part.part.type, PartType.text);
  });

  test('execution started marks the session busy', () {
    final events = translator.translate(_event(
      '{"id":"evt_3","created":1794172471263,"type":"session.execution.started",'
      '"data":{"sessionID":"ses_1"}}',
    ));
    final status = events.single as SessionStatusEvent;
    expect(status.sessionID, 'ses_1');
    expect(status.isBusy, isTrue);
  });

  test('step started synthesises an assistant message before any content', () {
    final events = translator.translate(_event(
      '{"id":"evt_4","created":1794172471307,"type":"session.step.started",'
      '"data":{"sessionID":"ses_1","agent":"build",'
      '"model":{"id":"mimo-v2.6-flash","providerID":"mimo-token-plan"},'
      '"assistantMessageID":"msg_2","started":1794172471367}}',
    ));
    final message = (events.single as MessageUpdatedEvent).info;
    expect(message.id, 'msg_2');
    expect(message.role, 'assistant');
    expect(message.agent, 'build');
    expect(message.modelID, 'mimo-v2.6-flash');
    expect(message.providerID, 'mimo-token-plan');
  });

  test('text deltas accumulate and reuse the existing assistant message', () {
    translator.translate(_event(
      '{"id":"evt_5","created":1794172471307,"type":"session.step.started",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","started":1}}',
    ));

    final first = translator.translate(_event(
      '{"id":"evt_6","created":1794172471308,"type":"session.text.delta",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","ordinal":0,'
      '"delta":"hello"}}',
    ));
    expect(first, hasLength(1));
    expect((first.single as MessagePartUpdatedEvent).part.text, 'hello');

    final second = translator.translate(_event(
      '{"id":"evt_7","created":1794172471309,"type":"session.text.delta",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","ordinal":0,'
      '"delta":" world"}}',
    ));
    expect((second.single as MessagePartUpdatedEvent).part.text, 'hello world');
  });

  test('text ended uses the authoritative full text', () {
    translator.translate(_event(
      '{"id":"evt_8","created":1,"type":"session.text.started",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","ordinal":0}}',
    ));
    final events = translator.translate(_event(
      '{"id":"evt_9","created":2,"type":"session.text.ended",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","ordinal":0,'
      '"text":"final text"}}',
    ));
    expect((events.single as MessagePartUpdatedEvent).part.text, 'final text');
  });

  test('tool success produces a completed tool part', () {
    translator.translate(_mapEvent('session.step.started', {
      'sessionID': 'ses_1',
      'assistantMessageID': 'msg_2',
      'started': 1,
    }));
    translator.translate(_mapEvent('session.tool.input.delta', {
      'sessionID': 'ses_1',
      'assistantMessageID': 'msg_2',
      'id': 'call_1',
      'delta': '{"path":"a.txt"}',
    }));
    final events = translator.translate(_event(
      '{"id":"evt_12","created":120,"type":"session.tool.success",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","id":"call_1",'
      '"content":[{"type":"text","text":"done"}],"metadata":{"title":"Read"},'
      '"executed":true}}',
    ));

    expect(events, hasLength(1));
    final part = (events.single as MessagePartUpdatedEvent).part;
    expect(part.type, PartType.tool);
    expect(part.callID, 'call_1');
    expect(part.state?.status, ToolStatus.completed);
    expect(part.state?.output, 'done');
    expect(part.state?.title, 'Read');
    expect((part.state?.input as Map)['path'], 'a.txt');
  });

  test('step ended records finish reason, tokens and cost', () {
    translator.translate(_event(
      '{"id":"evt_13","created":1,"type":"session.step.started",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","started":1}}',
    ));
    final events = translator.translate(_event(
      '{"id":"evt_14","created":1794172485033,"type":"session.step.ended",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","finish":"stop",'
      '"tokens":{"input":5996,"output":5,"reasoning":9,'
      '"cache":{"read":3072,"write":0}},"cost":0}}',
    ));
    final message = (events.single as MessageUpdatedEvent).info;
    expect(message.finish, 'stop');
    expect(message.completed, 1794172485033);
    expect(message.tokens?.input, 5996);
    expect(message.tokens?.cacheRead, 3072);
  });

  test('usage updated attributes cost and tokens to the latest assistant', () {
    translator.translate(_event(
      '{"id":"evt_15","created":1,"type":"session.step.started",'
      '"data":{"sessionID":"ses_1","assistantMessageID":"msg_2","started":1}}',
    ));
    final events = translator.translate(_event(
      '{"id":"evt_16","created":1794172485040,"type":"session.usage.updated",'
      '"data":{"sessionID":"ses_1","cost":0.05,'
      '"tokens":{"input":10,"output":2,"reasoning":0,'
      '"cache":{"read":0,"write":0}}}}',
    ));
    final message = (events.single as MessageUpdatedEvent).info;
    expect(message.cost, 0.05);
    expect(message.tokens?.input, 10);
  });

  test('execution succeeded marks the session idle', () {
    final events = translator.translate(_event(
      '{"id":"evt_17","created":1794172485045,"type":"session.execution.succeeded",'
      '"data":{"sessionID":"ses_1"}}',
    ));
    expect((events.single as SessionStatusEvent).isIdle, isTrue);
  });

  test('execution failed raises an error then idles', () {
    final events = translator.translate(_event(
      '{"id":"evt_18","created":1,"type":"session.execution.failed",'
      '"data":{"sessionID":"ses_1","error":{"message":"boom"}}}',
    ));
    expect(events, hasLength(2));
    expect((events[0] as SessionErrorEvent).message, 'boom');
    expect((events[1] as SessionStatusEvent).isIdle, isTrue);
  });

  test('permission asked becomes a permission request', () {
    final events = translator.translate(_event(
      '{"id":"evt_19","created":1,"type":"permission.asked",'
      '"data":{"id":"perm_1","sessionID":"ses_1","action":"bash",'
      '"resources":["rm -rf /tmp/x"]}}',
    ));
    final request = (events.single as PermissionAskedEvent).request;
    expect(request.id, 'perm_1');
    expect(request.action, 'bash');
    expect(request.resources.single, 'rm -rf /tmp/x');
  });

  test('form created becomes a question request (nested form payload)', () {
    final events = translator.translate(_event(
      '{"id":"evt_20","created":1,"type":"form.created",'
      '"data":{"form":{"id":"form_1","sessionID":"ses_1","title":"Pick one",'
      '"fields":[{"key":"mode","type":"string","title":"Mode",'
      '"options":[{"value":"fast","label":"Fast"}]}]}}}',
    ));
    final request = (events.single as QuestionAskedEvent).request;
    expect(request.id, 'form_1');
    expect(request.questions.single.header, 'Mode');
    expect(request.questions.single.options.single.value, 'fast');
  });

  test('session status retry carries its message', () {
    final events = translator.translate(_event(
      '{"id":"evt_21","created":1,"type":"session.status",'
      '"data":{"sessionID":"ses_1","status":{"type":"retry","attempt":2,'
      '"message":"rate limited","next":1794172500000}}}',
    ));
    final status = events.single as SessionStatusEvent;
    expect(status.status, 'retry');
    expect(status.retryMessage, 'rate limited');
    expect(status.retryNext, 1794172500000);
  });

  test('inbox cancelled removes the optimistic message', () {
    final events = translator.translate(_event(
      '{"id":"evt_22","created":1,"type":"session.inbox.cancelled",'
      '"data":{"sessionID":"ses_1","inboxID":"msg_1"}}',
    ));
    final removed = events.single as MessageRemovedEvent;
    expect(removed.messageID, 'msg_1');
  });

  test('filesystem changed carries the file and change kind', () {
    final events = translator.translate(_event(
      '{"id":"evt_23","created":1,"type":"filesystem.changed",'
      '"data":{"file":"lib/main.dart","event":"change"}}',
    ));
    final changed = events.single as FilesChangedEvent;
    expect(changed.file, 'lib/main.dart');
    expect(changed.change, 'change');
  });
}