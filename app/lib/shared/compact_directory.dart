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

class CompactDirectory extends StatelessWidget {
  const CompactDirectory({
    super.key,
    required this.items,
    required this.onExpand,
    this.loading = false,
    this.error,
    this.onRetry,
  });
  final List<CompactDirectoryItem> items;
  final VoidCallback onExpand;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 96,
    child: Material(
      color: const Color(0xffe7edf2),
      child: Column(
        children: [
          SizedBox(
            height: 48,
            width: double.infinity,
            child: TextButton.icon(
              key: const Key('compact-directory-expand'),
              onPressed: onExpand,
              icon: const Icon(Icons.menu_open, size: 19),
              label: const Text('展开', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
            ),
          ),
          const Divider(height: 1),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: error != null
                ? Center(
                    child: TextButton(
                      onPressed: onRetry,
                      child: const Text(
                        '读取失败\n点击重试',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : items.isEmpty
                ? Center(
                    child: Text(
                      loading ? '读取中…' : '暂无目录',
                      style: const TextStyle(fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    itemCount: items.length,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final color = item.selected
                          ? const Color(0xff176dad)
                          : const Color(0xff425d73);
                      return Tooltip(
                        message: [
                          item.group,
                          item.label,
                        ].where((v) => v.isNotEmpty).join(' / '),
                        child: Material(
                          color: item.selected
                              ? const Color(0xffd4e5f3)
                              : Colors.transparent,
                          child: InkWell(
                            key: ValueKey('compact-directory-${item.id}'),
                            onTap: item.onTap,
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 64),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                border: Border(
                                  left: BorderSide(
                                    width: 3,
                                    color: item.selected
                                        ? color
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              child: Column(
                                children: [
                                  Icon(
                                    item.icon,
                                    size: 20,
                                    color: item.onTap == null
                                        ? Colors.grey
                                        : color,
                                  ),
                                  const SizedBox(height: 5),
                                  if (item.group.isNotEmpty &&
                                      item.group != item.label)
                                    Text(
                                      item.group,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        height: 1.3,
                                        color: Color(0xff74818e),
                                      ),
                                    ),
                                  Text(
                                    item.label,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.35,
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
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
