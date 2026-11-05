import 'package:flutter/material.dart';

/// A narrow, directly actionable directory; expanding is a separate action.
class CompactDirectoryItem {
  const CompactDirectoryItem({
    required this.id,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.group = '',
    this.icon = Icons.account_tree_outlined,
  });
  final String id, label, group;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;
}

class CompactDirectory extends StatefulWidget {
  const CompactDirectory({
    super.key,
    required this.items,
    required this.onExpand,
    this.onCollapse,
    this.loading = false,
    this.error,
    this.onRetry,
  });
  final List<CompactDirectoryItem> items;
  final VoidCallback onExpand;
  final VoidCallback? onCollapse;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  State<CompactDirectory> createState() => _CompactDirectoryState();
}

class _CompactDirectoryState extends State<CompactDirectory> {
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final items = widget.items
        .where(
          (item) => '${item.group} ${item.label}'.toLowerCase().contains(query),
        )
        .toList();
    return SizedBox(
      key: const Key('mobile-directory-dock'),
      height: 154,
      width: double.infinity,
      child: Material(
        color: const Color(0xffedf2f6),
        child: Column(
          children: [
            const Divider(height: 1),
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.only(left: 10, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('compact-directory-search'),
                        controller: search,
                        onChanged: (_) => setState(() {}),
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => FocusScope.of(context).unfocus(),
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: '搜索页面或站点',
                          constraints: const BoxConstraints(minHeight: 44),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 10,
                          ),
                          prefixIcon: const Icon(Icons.search, size: 19),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 36,
                          ),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清空搜索',
                                  onPressed: () => setState(search.clear),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      key: const Key('compact-directory-expand'),
                      tooltip: '展开完整目录',
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        widget.onExpand();
                      },
                      icon: const Icon(Icons.unfold_more, size: 21),
                    ),
                    if (widget.onCollapse != null) const SizedBox(width: 8),
                    if (widget.onCollapse != null)
                      IconButton(
                        key: const Key('compact-directory-collapse'),
                        tooltip: '收起目录',
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                        onPressed: () {
                          FocusScope.of(context).unfocus();
                          widget.onCollapse!();
                        },
                        icon: const Icon(Icons.keyboard_arrow_down, size: 23),
                      ),
                  ],
                ),
              ),
            ),
            if (widget.loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: widget.error != null
                  ? Center(
                      child: TextButton(
                        onPressed: widget.onRetry,
                        child: const Text('读取失败，点击重试'),
                      ),
                    )
                  : items.isEmpty
                  ? Center(
                      child: Text(
                        widget.loading
                            ? '读取中…'
                            : query.isEmpty
                            ? '暂无目录'
                            : '没有匹配的页面',
                        style: const TextStyle(fontSize: 12),
                      ),
                    )
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (context, i) {
                        final item = items[i];
                        final color = item.selected
                            ? const Color(0xff176dad)
                            : const Color(0xff425d73);
                        return SizedBox(
                          width: 112,
                          child: Tooltip(
                            message: [
                              item.group,
                              item.label,
                            ].where((v) => v.isNotEmpty).join(' / '),
                            child: Material(
                              color: item.selected
                                  ? const Color(0xffd4e5f3)
                                  : const Color(0xfff8fafc),
                              borderRadius: BorderRadius.circular(8),
                              child: InkWell(
                                key: ValueKey('compact-directory-${item.id}'),
                                borderRadius: BorderRadius.circular(8),
                                onTap: item.onTap == null
                                    ? null
                                    : () {
                                        FocusScope.of(context).unfocus();
                                        item.onTap!();
                                      },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 7,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        item.icon,
                                        size: 18,
                                        color: item.onTap == null
                                            ? Colors.grey
                                            : color,
                                      ),
                                      const SizedBox(height: 4),
                                      if (item.group.isNotEmpty &&
                                          item.group != item.label)
                                        Text(
                                          item.group,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            height: 1.2,
                                            color: Color(0xff74818e),
                                          ),
                                        ),
                                      Text(
                                        item.label,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.2,
                                          color: color,
                                          fontWeight: item.selected
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A bounded touch target that moves independently of the page below it.
class MobileDirectoryHandle extends StatefulWidget {
  const MobileDirectoryHandle({super.key, required this.onRestore});
  final VoidCallback onRestore;
  @override
  State<MobileDirectoryHandle> createState() => _MobileDirectoryHandleState();
}

class _MobileDirectoryHandleState extends State<MobileDirectoryHandle> {
  Offset? position;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final maxX = (box.maxWidth - 48).clamp(0.0, double.infinity);
      final maxY = (box.maxHeight - 48).clamp(0.0, double.infinity);
      Offset bounded(Offset p) =>
          Offset(p.dx.clamp(0.0, maxX), p.dy.clamp(0.0, maxY));
      final at = bounded(position ?? Offset(maxX - 4, box.maxHeight - 146));
      return Stack(
        children: [
          Positioned(
            left: at.dx,
            top: at.dy,
            child: GestureDetector(
              onPanUpdate: (details) =>
                  setState(() => position = bounded(at + details.delta)),
              child: Material(
                color: const Color(0xb3dce7f0),
                borderRadius: BorderRadius.circular(24),
                child: IconButton(
                  key: const Key('mobile-directory-restore'),
                  tooltip: '展开目录（可拖动）',
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  onPressed: widget.onRestore,
                  icon: const Icon(Icons.menu_open, color: Color(0xff294d69)),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
