import 'package:flutter/material.dart';
import '../../shared/desktop_sidebar.dart';

const materialSections = {
  'applications': '申请与审批',
  'catalog': '品类管理',
  'inbound': '入库管理',
  'stock': '库存管理',
  'outbound': '出库管理',
  'chains': '操作日志',
};
const materialSectionIcons = {
  'applications': Icons.fact_check_outlined,
  'catalog': Icons.category_outlined,
  'inbound': Icons.move_to_inbox_outlined,
  'stock': Icons.inventory_2_outlined,
  'outbound': Icons.outbox_outlined,
  'chains': Icons.account_tree_outlined,
};

class MaterialNavigation extends StatelessWidget {
  const MaterialNavigation({
    super.key,
    required this.sections,
    required this.selected,
    required this.onSelect,
    required this.onHide,
    this.compact = false,
    this.onExpand,
    this.categoryBrowser,
  });
  final List<String> sections;
  final String selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onHide;
  final VoidCallback? onExpand;
  final bool compact;
  final Widget? categoryBrowser;

  @override
  Widget build(BuildContext context) {
    if (!compact) {
      return DesktopSidebar(
        title: '物料管理',
        actions: [
          IconButton(
            tooltip: '收起物料目录',
            onPressed: onHide,
            icon: const Icon(Icons.chevron_left, size: 18),
          ),
        ],
        child: Column(
          children: [
            Expanded(
              flex: categoryBrowser == null ? 1 : 2,
              child: ListView(
                padding: const EdgeInsets.only(top: 4),
                children: [
                  for (final key in sections)
                    DesktopSidebarRow(
                      key: ValueKey('materials-section-$key'),
                      title: materialSections[key]!,
                      icon: materialSectionIcons[key]!,
                      selected: selected == key,
                      onTap: () => onSelect(key),
                    ),
                ],
              ),
            ),
            if (categoryBrowser != null)
              Expanded(flex: 3, child: categoryBrowser!),
          ],
        ),
      );
    }
    return ColoredBox(
      color: DesktopSidebar.panel,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: IconButton(
                  tooltip: '展开物料目录',
                  onPressed: onExpand,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  icon: const Icon(Icons.menu_open, size: 20),
                ),
              ),
              Expanded(
                child: IconButton(
                  tooltip: '收起物料目录',
                  onPressed: onHide,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  icon: const Icon(Icons.chevron_left, size: 20),
                ),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                for (final key in sections)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Material(
                      color: selected == key
                          ? DesktopSidebar.selection
                          : Colors.transparent,
                      child: InkWell(
                        key: ValueKey('materials-section-$key'),
                        onTap: () => onSelect(key),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 10,
                            ),
                            child: Text(
                              materialSections[key]!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: DesktopSidebar.ink,
                                fontWeight: selected == key
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
