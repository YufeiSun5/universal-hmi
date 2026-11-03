import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/layout_audit.dart';

List<Map<String, Object>> lintUI(
  WidgetTester tester, {
  double minTarget = 44,
  double minGap = 8,
}) => measureLayout(
  find.byType(RichText).evaluate(),
  find.byWidgetPredicate(isLayoutControl).hitTestable().evaluate(),
  minTarget: minTarget,
  minGap: minGap,
);

void expectCleanUI(WidgetTester tester, String page) {
  final exception = tester.takeException();
  expect(exception, isNull, reason: '$page: layout exception');
  final issues = lintUI(tester);
  expect(issues, isEmpty, reason: jsonEncode({'page': page, 'issues': issues}));
}
