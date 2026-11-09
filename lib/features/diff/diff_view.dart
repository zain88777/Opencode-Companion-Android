import 'package:flutter/material.dart';

enum DiffLineType { add, remove, context }

class DiffLine {
  const DiffLine({required this.type, required this.text});

  final DiffLineType type;
  final String text;
}

/// Above this size the O(a.length * b.length) LCS table becomes an OOM/ANR risk
/// on-device, so a simple truncated remove-then-add diff is used instead.
const int _maxDiffLines = 800;
const int _maxDiffCells = 250000;
const int _truncatedSideLines = 400;

/// Computes a line diff between two versions of a file.
///
/// Ported from the reference client's diff-compute.ts: LCS with a 3-line context
/// collapse, CRLF normalisation, and a hard size guard.
List<DiffLine> computeDiff(String before, String after) {
  final a = before.split(RegExp(r'\r?\n'));
  final b = after.split(RegExp(r'\r?\n'));

  if (a.length > _maxDiffLines ||
      b.length > _maxDiffLines ||
      a.length * b.length > _maxDiffCells) {
    final removed = a
        .take(_truncatedSideLines)
        .map((text) => DiffLine(type: DiffLineType.remove, text: text))
        .toList();
    final added = b
        .take(_truncatedSideLines)
        .map((text) => DiffLine(type: DiffLineType.add, text: text))
        .toList();
    return [
      ...removed,
      ...added,
      DiffLine(
        type: DiffLineType.context,
        text:
            '.. diff too large to display in full (${a.length + b.length} lines) - view on your computer',
      ),
    ];
  }

  final m = a.length;
  final n = b.length;
  final dp = List.generate(m + 1, (_) => List<int>.filled(n + 1, 0));

  for (var i = 1; i <= m; i++) {
    for (var j = 1; j <= n; j++) {
      dp[i][j] = a[i - 1] == b[j - 1]
          ? dp[i - 1][j - 1] + 1
          : (dp[i - 1][j] >= dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1]);
    }
  }

  var result = <DiffLine>[];
  var i = m;
  var j = n;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && a[i - 1] == b[j - 1]) {
      result.add(DiffLine(type: DiffLineType.context, text: a[i - 1]));
      i--;
      j--;
    } else if (j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j])) {
      result.add(DiffLine(type: DiffLineType.add, text: b[j - 1]));
      j--;
    } else {
      result.add(DiffLine(type: DiffLineType.remove, text: a[i - 1]));
      i--;
    }
  }
  result = result.reversed.toList();

  // Collapse long context runs: show at most 3 context lines between changes.
  final collapsed = <DiffLine>[];
  var contextRun = 0;
  for (final line in result) {
    if (line.type == DiffLineType.context) {
      contextRun++;
      if (contextRun <= 3) {
        collapsed.add(line);
      } else if (contextRun == 4) {
        collapsed.add(const DiffLine(type: DiffLineType.context, text: '...'));
      }
    } else {
      contextRun = 0;
      collapsed.add(line);
    }
  }
  return collapsed;
}

/// Renders a unified diff, coloured by line type.
///
/// A side-by-side layout does not fit a 720x1600 phone, so this is a single
/// unified column - the right call for the target device.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.before, required this.after});

  final String before;
  final String after;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = computeDiff(before, after);

    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        final (color, prefix) = switch (line.type) {
          DiffLineType.add => (scheme.primaryContainer, '+'),
          DiffLineType.remove => (scheme.errorContainer, '-'),
          DiffLineType.context => (scheme.surfaceContainerLow, ' '),
        };
        return Container(
          color: color,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Text(
            '$prefix ${line.text}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
              color: scheme.onSurface,
            ),
          ),
        );
      },
    );
  }
}

/// Renders a unified diff that arrived as a patch string from the server.
class UnifiedPatchView extends StatelessWidget {
  const UnifiedPatchView({super.key, required this.patch});

  final String patch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = patch.split('\n');
    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];
        Color? color;
        if (line.startsWith('+') && !line.startsWith('+++')) {
          color = scheme.primaryContainer;
        } else if (line.startsWith('-') && !line.startsWith('---')) {
          color = scheme.errorContainer;
        }
        return Container(
          color: color ?? scheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Text(
            line,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.35,
              color: scheme.onSurface,
            ),
          ),
        );
      },
    );
  }
}