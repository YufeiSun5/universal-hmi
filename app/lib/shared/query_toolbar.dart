import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'query_control_theme.dart';

/// At most three visible control rows. Primary actions stay outside the
/// scrollable conditions, so changing a narrow viewport never hides submit.
class QueryToolbar extends StatefulWidget {
  const QueryToolbar({
    super.key,
    required this.fields,
    this.actions = const [],
    this.maxHeight = double.infinity,
    this.minControlHeight = 0,
  });
  final List<Widget> fields, actions;
  final double maxHeight, minControlHeight;

  @override
  State<QueryToolbar> createState() => _QueryToolbarState();
}

class _QueryToolbarState extends State<QueryToolbar> {
  final scroll = ScrollController();
  final actionScroll = ScrollController();

  @override
  void dispose() {
    scroll.dispose();
    actionScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => QueryControlTheme(
    minHeight: widget.minControlHeight,
    child: Builder(
      builder: (context) => LayoutBuilder(
        builder: (context, box) {
          final height = QueryControlTheme.controlHeight(
            context,
          ).clamp(widget.minControlHeight, double.infinity);
          final width = math.max(0.0, box.maxWidth - 22);
          final available = math.min(widget.maxHeight, box.maxHeight);
          final actions = widget.actions.isNotEmpty;
          final short = available < height * 2 + 34;
          final rows = actions ? 2 : 3;
          final footer = actions ? height + 8 : 0.0;
          final budget = math.max(1.0, available - footer - 18);
          final visibleRows = ((budget + 2) / (height + 10))
              .clamp(1, rows)
              .floor();
          final fieldHeight = math.min(
            visibleRows * height + (visibleRows - 1) * 10 + 8,
            budget,
          );
          final colors = Theme.of(context).colorScheme;
          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? colors.surfaceContainerLow
                  : const Color(0xfff1f4f7),
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: short && actions
                ? Row(
                    children: [
                      widget.actions.first,
                      const SizedBox(width: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: scroll,
                          primary: false,
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              for (final child in [
                                ...widget.actions.skip(1),
                                ...widget.fields,
                              ])
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: child,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.fields.isNotEmpty)
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: fieldHeight),
                          child: Scrollbar(
                            controller: scroll,
                            thickness: 3,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: scroll,
                              primary: false,
                              padding: const EdgeInsets.fromLTRB(0, 6, 8, 2),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 10,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  for (final child in [...widget.fields])
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: math.max(0, width - 8),
                                      ),
                                      child: child,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (actions) ...[
                        if (widget.fields.isNotEmpty) const SizedBox(height: 8),
                        SizedBox(
                          height: height,
                          child: Scrollbar(
                            controller: actionScroll,
                            thickness: 3,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: actionScroll,
                              primary: false,
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (
                                    var i = 0;
                                    i < widget.actions.length;
                                    i++
                                  ) ...[
                                    if (i > 0) const SizedBox(width: 8),
                                    widget.actions[i],
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          );
        },
      ),
    ),
  );
}

class QueryHeading extends StatelessWidget {
  const QueryHeading({super.key, required this.title, this.actions = const []});
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => QueryControlTheme(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (actions.isNotEmpty)
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
