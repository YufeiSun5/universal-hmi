import 'api.dart';

class PageDestination {
  const PageDestination({
    required this.id,
    required this.page,
    required this.label,
    this.configured = true,
    this.mobile = true,
  });
  factory PageDestination.fromJson(Json v) => PageDestination(
    id: '${v['id']}',
    page: v['page'] as int,
    label: '${v['label']}',
    configured: v['configured'] == true,
    mobile: v['mobile'] == true,
  );
  final String id, label;
  final int page;
  final bool configured, mobile;
}

class HomeLanding {
  const HomeLanding(this.destination, [this.reason = '']);
  final PageDestination? destination;
  final String reason;
  int get page => destination?.page ?? 21;
  String? get materialSection =>
      destination?.id.startsWith('materials/') == true
      ? destination!.id.split('/').last
      : null;
}

class PageAccess {
  PageAccess.fromJson(Json v)
    : pages = objects(v['pages']).map(PageDestination.fromJson).toList(),
      home = (v['preferences'] as Json?)?['home']?.toString() ?? '',
      revision = (v['preferences'] as Json?)?['revision'] as int? ?? 0;
  final List<PageDestination> pages;
  final String home;
  final int revision;
  List<PageDestination> supported(bool mobile) =>
      pages.where((p) => !mobile || p.mobile).toList();
  Set<int> allowedPages(bool mobile) =>
      supported(mobile).map((p) => p.page).toSet();
  PageDestination? find(
    String id,
    bool mobile, {
    bool requireConfigured = false,
  }) {
    for (final p in supported(mobile)) {
      if ((p.id == id || id == 'materials' && p.page == 20) &&
          (!requireConfigured || p.configured)) {
        return p;
      }
    }
    return null;
  }

  HomeLanding resolve({
    String? explicitView,
    required bool mobile,
    bool developmentDefault = false,
  }) {
    var requested = explicitView ?? '';
    requested =
        const {
          'external': 'history',
          'external-data': 'history',
          'alarm': 'alarms',
        }[requested] ??
        requested;
    final explicit = requested.isNotEmpty && requested != 'runtime';
    if (explicit) {
      final p = find(requested, mobile);
      if (p != null) return HomeLanding(p);
    }
    if (home.isNotEmpty) {
      final p = find(home, mobile, requireConfigured: true);
      if (p != null) {
        return HomeLanding(p, explicit ? '原链接当前不可访问，已打开本人首页。' : '');
      }
    }
    final reason = home.isNotEmpty
        ? '原首页在当前终端不可用、未配置或权限已变化，已临时回退；账号首页设置保持不变。'
        : explicit
        ? '原链接当前不可访问，已打开可访问页面。'
        : '';
    for (final id in [
      if (developmentDefault &&
          !explicit &&
          home.isEmpty &&
          requested != 'runtime')
        'workbench',
      mobile ? 'overview' : 'gis',
      'overview',
      'process',
    ]) {
      final p = find(id, mobile, requireConfigured: true);
      if (p != null) return HomeLanding(p, reason);
    }
    final available = supported(
      mobile,
    ).where((p) => p.configured && p.id != 'workbench').toList();
    if (available.isNotEmpty) return HomeLanding(available.first, reason);
    final readable = supported(mobile);
    return HomeLanding(readable.isEmpty ? null : readable.first, reason);
  }
}
