import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  final runs = _QueryRuns();

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
          final screenBudget = MediaQuery.sizeOf(context).height < 500
              ? height + 32
              : double.infinity;
          final available = math.min(
            screenBudget,
            math.min(widget.maxHeight, box.maxHeight),
          );
          final actions = widget.actions.isNotEmpty;
          final short = available < height * 2 + 34;
          final contentHeight = math.min(
            height * 3 + 28,
            math.max(1.0, available - 18),
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
                      Expanded(
                        child: SingleChildScrollView(
                          controller: scroll,
                          primary: false,
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              for (final child in [...widget.fields])
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: child,
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: width * .65),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.actions.length > 1) ...[
                              Flexible(
                                child: SingleChildScrollView(
                                  controller: actionScroll,
                                  primary: false,
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (final child in widget.actions.skip(
                                        1,
                                      ))
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: child,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            widget.actions.first,
                          ],
                        ),
                      ),
                    ],
                  )
                : _QueryLayout(
                    runs: runs,
                    rowHeight: height,
                    maxHeight: contentHeight,
                    hasActions: actions,
                    children: [
                      Scrollbar(
                        controller: scroll,
                        thickness: 3,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: scroll,
                          primary: false,
                          padding: const EdgeInsets.fromLTRB(0, 6, 0, 2),
                          child: _QueryWrap(
                            runs: runs,
                            direction: Directionality.of(context),
                            children: [
                              for (final child in [...widget.fields])
                                ConstrainedBox(
                                  constraints: BoxConstraints(maxWidth: width),
                                  child: child,
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (actions)
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
                                mainAxisSize: MainAxisSize.min,
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
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
          );
        },
      ),
    ),
  );
}

// Render-time measurements keep fields and actions in the same widget tree
// while using the actual remaining space in the final condition row.
class _QueryRuns {
  double contentHeight = 0;
  Offset trailingCenter = Offset.zero;
}

class _QueryWrap extends MultiChildRenderObjectWidget {
  const _QueryWrap({
    required this.runs,
    required this.direction,
    required super.children,
  });
  final _QueryRuns runs;
  final TextDirection direction;

  @override
  _RenderQueryWrap createRenderObject(BuildContext context) =>
      _RenderQueryWrap(runs, direction);

  @override
  void updateRenderObject(BuildContext context, _RenderQueryWrap renderObject) {
    renderObject.runs = runs;
    renderObject.textDirection = direction;
  }
}

class _RenderQueryWrap extends RenderWrap {
  _RenderQueryWrap(this.runs, TextDirection direction)
    : super(
        spacing: 8,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        textDirection: direction,
      );

  _QueryRuns runs;

  @override
  void performLayout() {
    super.performLayout();
    runs.contentHeight = size.height;
    final child = lastChild;
    if (child == null) {
      runs.trailingCenter = Offset.zero;
      return;
    }
    final offset = (child.parentData! as WrapParentData).offset;
    runs.trailingCenter = Offset(
      offset.dx + child.size.width,
      offset.dy + child.size.height / 2,
    );
  }
}

class _QueryLayout extends MultiChildRenderObjectWidget {
  const _QueryLayout({
    required this.runs,
    required this.rowHeight,
    required this.maxHeight,
    required this.hasActions,
    required super.children,
  });
  final _QueryRuns runs;
  final double rowHeight, maxHeight;
  final bool hasActions;

  @override
  _RenderQueryLayout createRenderObject(BuildContext context) =>
      _RenderQueryLayout(runs, rowHeight, maxHeight, hasActions);

  @override
  void updateRenderObject(BuildContext context, _RenderQueryLayout object) {
    object
      ..runs = runs
      ..rowHeight = rowHeight
      ..maxHeight = maxHeight
      ..hasActions = hasActions
      ..markNeedsLayout();
  }
}

class _QueryParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderQueryLayout extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          ContainerBoxParentData<RenderBox>
        > {
  _RenderQueryLayout(
    this.runs,
    this.rowHeight,
    this.maxHeight,
    this.hasActions,
  );
  _QueryRuns runs;
  double rowHeight, maxHeight;
  bool hasActions;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ContainerBoxParentData<RenderBox>) {
      child.parentData = _QueryParentData();
    }
  }

  @override
  void performLayout() {
    final fields = firstChild!;
    final actions = lastChild!;
    final width = constraints.maxWidth;
    final limit = math.min(maxHeight, constraints.maxHeight);
    actions.layout(
      BoxConstraints(maxWidth: width, maxHeight: rowHeight),
      parentUsesSize: true,
    );
    fields.layout(
      BoxConstraints(maxWidth: width, maxHeight: limit),
      parentUsesSize: true,
    );
    final trailing = runs.trailingCenter;
    final actionTop = math.max(6.0, trailing.dy + 6 - rowHeight / 2);
    final sharesRow =
        runs.contentHeight + 8 <= fields.size.height + .01 &&
        trailing.dx + 8 + actions.size.width <= width &&
        actionTop + actions.size.height + 2 <= limit;
    var contentHeight = fields.size.height;
    var actionY = actionTop;
    if (hasActions && !sharesRow) {
      fields.layout(
        BoxConstraints(
          maxWidth: width,
          maxHeight: math.max(1.0, limit - rowHeight - 8),
        ),
        parentUsesSize: true,
      );
      actionY = fields.size.height + 8;
    }
    if (hasActions) {
      contentHeight = math.max(contentHeight, actionY + actions.size.height);
      // The first layout may have allowed a third condition row. When actions
      // need their own row, only the second (bounded) field layout counts.
      if (!sharesRow) contentHeight = actionY + actions.size.height;
    }
    (fields.parentData! as BoxParentData).offset = Offset.zero;
    (actions.parentData! as BoxParentData).offset = Offset(
      width - actions.size.width,
      hasActions ? actionY : 0,
    );
    size = constraints.constrain(Size(width, contentHeight));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
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
