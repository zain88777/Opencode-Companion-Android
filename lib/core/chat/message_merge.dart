import '../api/models.dart';

/// Merge a server `message.updated` event into the current message list.
///
/// Optimistic sends add placeholder messages with `temp-` ids. When the real
/// server message arrives we must replace ONLY the oldest still-pending
/// optimistic message of the same role - not every `temp-` message.
///
/// The bug this guards against: sending a second message while the first is
/// still processing leaves two `temp-` user messages in the list. A naive
/// "drop all temp messages when any real one arrives" would remove BOTH when
/// the first real message lands, so the second (already queued server-side but
/// not yet echoed back) vanishes from the chat until its own event arrives.
List<Message> mergeIncomingMessage(List<Message> messages, Message message) {
  for (var i = 0; i < messages.length; i++) {
    if (messages[i].id == message.id) {
      final next = List<Message>.from(messages);
      next[i] = message;
      return next;
    }
  }

  for (var i = 0; i < messages.length; i++) {
    if (messages[i].id.startsWith('temp-') && messages[i].role == message.role) {
      final next = List<Message>.from(messages);
      next[i] = message;
      return next;
    }
  }

  return [...messages, message];
}

/// Merge a `message.part.updated` event: replace in place when the part id is
/// already known, otherwise append. Parts arrive in order, but a replacement is
/// what carries the accumulated text.
List<Part> mergeIncomingPart(List<Part> parts, Part part) {
  for (var i = 0; i < parts.length; i++) {
    if (parts[i].id == part.id) {
      final next = List<Part>.from(parts);
      next[i] = part;
      return next;
    }
  }
  return [...parts, part];
}

/// Drop pending `temp-` messages of [role] - used when a send is cancelled.
List<Message> dropPending(List<Message> messages, String role) => messages
    .where((m) => !(m.id.startsWith('temp-') && m.role == role))
    .toList();