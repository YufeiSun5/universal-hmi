import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// A timezone-independent Beijing wall clock for form fields.
DateTime beijingNow() => DateTime.now().toUtc().add(const Duration(hours: 8));
String beijingText(DateTime t, {bool time = false}) =>
    t.toIso8601String().substring(0, time ? 16 : 10);
String beijingIso(String text) {
  final raw = text.trim();
  if (RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(raw)) return raw;
  return '${raw.length == 10
      ? '${raw}T00:00:00'
      : raw.length == 16
      ? '$raw:00'
      : raw}+08:00';
}

/// Calendar arithmetic uses UTC-valued wall-clock components so host DST and
/// local zone never alter the length of a Beijing date/time selection.
DateTime? beijingWall(String text) =>
    DateTime.tryParse(beijingIso(text))?.toUtc().add(const Duration(hours: 8));
String beijingStamp(DateTime wall) =>
    wall.toIso8601String().replaceFirst(RegExp(r'Z$'), '');

class DateTimeField extends StatelessWidget {
  const DateTimeField({
    super.key,
    required this.controller,
    required this.label,
    this.includeTime = false,
    this.enabled = true,
    this.onChanged,
    this.firstDate,
    this.lastDate,
    this.isoOutput = false,
  });
  final TextEditingController controller;
  final String label;
  final bool includeTime, enabled, isoOutput;
  final ValueChanged<String>? onChanged;
  final DateTime? firstDate, lastDate;

  Widget localized(BuildContext context, Widget child) =>
      Localizations.override(
        context: context,
        locale: const Locale('zh', 'CN'),
        delegates: GlobalMaterialLocalizations.delegates,
        child: Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme: Theme.of(context).inputDecorationTheme
                .copyWith(constraints: const BoxConstraints(minHeight: 48)),
          ),
          child: child,
        ),
      );

  Future<void> pick(BuildContext context) async {
    final raw = DateTime.tryParse(controller.text);
    final t = raw == null
        ? beijingNow()
        : raw.isUtc
        ? raw.add(const Duration(hours: 8))
        : raw;
    final first = firstDate ?? DateTime(2000);
    final last = lastDate ?? DateTime(2100, 12, 31);
    final initial = DateTime(t.year, t.month, t.day);
    final selected = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(first)
          ? first
          : initial.isAfter(last)
          ? last
          : initial,
      firstDate: first,
      lastDate: last,
      helpText: '$label · 北京时间',
      cancelText: '取消',
      confirmText: '确定',
      builder: (context, child) => localized(context, child!),
    );
    if (selected == null || !context.mounted) return;
    var value = selected;
    if (includeTime) {
      final clock = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(hour: t.hour, minute: t.minute),
        helpText: '选择时间 · UTC+8',
        cancelText: '取消',
        confirmText: '确定',
        builder: (context, child) => localized(
          context,
          MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
            child: child!,
          ),
        ),
      );
      if (clock == null || !context.mounted) return;
      value = DateTime(
        selected.year,
        selected.month,
        selected.day,
        clock.hour,
        clock.minute,
      );
    }
    controller.text = beijingText(value, time: includeTime);
    if (isoOutput) controller.text = beijingIso(controller.text);
    onChanged?.call(controller.text);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      hintText: includeTime ? 'YYYY-MM-DD HH:mm · UTC+8' : 'YYYY-MM-DD',
      suffixIcon: IconButton(
        tooltip: '选择$label',
        onPressed: enabled ? () => pick(context) : null,
        icon: const Icon(Icons.calendar_month_outlined, size: 19),
      ),
    ),
  );
}
