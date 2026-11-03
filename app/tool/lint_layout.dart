import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

/// Inspect Flutter layout expressions in every library, including dialog
/// builders and local helper functions. Runtime tests measure actual sizes.
class LayoutVisitor extends RecursiveAstVisitor<void> {
  LayoutVisitor(this.file, this.lines, this.issues);
  final String file;
  final LineInfo lines;
  final List<Map<String, Object>> issues;
  int dialogs = 0, layouts = 0;
  static const fields = {
    'TextField',
    'TextFormField',
    'DropdownButtonFormField',
    'DropdownMenu',
  };
  void issue(String rule, AstNode node) => issues.add({
    'file': file,
    'line': lines.getLocation(node.offset).lineNumber,
    'rule': rule,
  });

  @override
  void visitMethodInvocation(MethodInvocation node) {
    inspect(node.methodName.name, node.argumentList);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    inspect(node.constructorName.type.name2.lexeme, node.argumentList);
    super.visitInstanceCreationExpression(node);
  }

  String? callName(CollectionElement element) => switch (element) {
    MethodInvocation n => n.methodName.name,
    InstanceCreationExpression n => n.constructorName.type.name2.lexeme,
    _ => null,
  };
  void inspect(String name, ArgumentList args) {
    final named = {
      for (final arg in args.arguments.whereType<NamedExpression>())
        arg.name.label.name: arg.expression,
    };
    if (const {
      'AlertDialog',
      'SimpleDialog',
      'Dialog',
      'BottomSheet',
    }.contains(name)) {
      dialogs++;
      final inset = named['insetPadding'];
      if (inset != null &&
          (inset.toSource() == 'EdgeInsets.zero' ||
              RegExp(
                r'EdgeInsets\.all\([0-7](?:\.0)?\)$',
              ).hasMatch(inset.toSource()))) {
        issue('dialog-edge-inset', inset);
      }
    }
    if (!const {'Column', 'Row', 'Wrap'}.contains(name)) return;
    layouts++;
    final children = named['children'];
    if (children is! ListLiteral) return;
    bool tooSmall(String key) {
      final arg = named[key];
      final value = arg == null ? 0 : double.tryParse(arg.toSource());
      return value != null && value < 8;
    }

    if (!tooSmall('spacing') && (name != 'Wrap' || !tooSmall('runSpacing'))) {
      return;
    }
    var previousField = false;
    for (final child in children.elements) {
      final field = fields.contains(callName(child));
      if (previousField && field) issue('adjacent-form-fields', child);
      previousField = field;
    }
  }
}

void main(List<String> args) {
  final issues = <Map<String, Object>>[];
  var files = 0, dialogs = 0, layouts = 0;
  final sources =
      Directory(args.isEmpty ? 'lib' : args.single)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in sources) {
    final unit = parseString(path: file.path, content: file.readAsStringSync());
    final visitor = LayoutVisitor(
      file.path.replaceAll('\\', '/'),
      unit.lineInfo,
      issues,
    );
    unit.unit.accept(visitor);
    files++;
    dialogs += visitor.dialogs;
    layouts += visitor.layouts;
  }
  stdout.writeln(
    jsonEncode({
      'files': files,
      'layouts': layouts,
      'dialogs': dialogs,
      'issues': issues,
    }),
  );
  if (files == 0 || issues.isNotEmpty) exitCode = 1;
}
