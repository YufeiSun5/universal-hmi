import 'security_layout.dart';
import 'security_page.dart';
import 'package:flutter/material.dart';
import '../shared/api.dart';

/// Bounded view of server-generated request records, not a browsing history.
class PublicAccessEventsPanel extends StatefulWidget {
  const PublicAccessEventsPanel({super.key, required this.api});
  final PlatformApi api;
  @override
  State<PublicAccessEventsPanel> createState() =>
      _PublicAccessEventsPanelState();
}

class _PublicAccessEventsPanelState extends State<PublicAccessEventsPanel> {
  static const maximum = 500;
  List<Json> events = [];
  Json? status;
  String scope = 'all', search = '', outcome = 'all', channel = '';
  int? expanded;
  bool showService = false;
  int before = 0, generation = 0;
  bool busy = false, loaded = false, closing = false;
  String? error;

  @override
  void initState() {
    super.initState();
    load(reset: true);
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (busy || (!reset && (before == 0 || events.length >= maximum))) return;
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        '/api/v1/security/public-access/events',
        query: {'limit': 100, if (!reset) 'before': before},
      );
      if (!mounted || request != generation) return;
      final incoming = objects(result['items']);
      final next = result['next_before'];
      final health = result['status'];
      if (next is! int || next < 0 || health is! Map) {
        throw const FormatException('请求记录响应格式无效');
      }
      setState(() {
        final combined = reset ? <Json>[] : List<Json>.from(events);
        final seen = combined.map((e) => e['seq']).toSet();
        for (final event in incoming) {
          if (combined.length >= maximum) break;
          if (seen.add(event['seq'])) combined.add(event);
        }
        events = combined;
        if (channel.isNotEmpty && !events.any((e) => e['channel'] == channel)) {
          channel = '';
        }
        if (!events.any((e) => e['seq'] == expanded)) expanded = null;
        before = next;
        status = Map<String, dynamic>.from(health);
        scope = result['scope']?.toString() ?? 'all';
        loaded = true;
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() => error = '请求记录加载失败。已有记录仅为先前结果，不能据此判断记录完整或公网安全。');
      }
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  String decision(Object? value) =>
      const {
        'allowed': '允许',
        'public_ip_denied': 'IP 白名单拒绝',
        'public_device_denied': '设备未授权',
        'public_peer_denied': '来源地址无效',
        'public_guard_unavailable': '防护状态不可用',
        'public_peer_banned': '来源 IP 已封禁',
        'public_rate_limited': '请求限流',
        'public_waf_denied': '攻击防护拦截',
        'public_read_only': '公网只读限制',
        'public_path_denied': '公网路径拒绝',
        'authentication_required': '需要认证',
        'authentication_failed': '登录认证失败',
        'forbidden': '权限拒绝',
        'request_failed': '请求失败',
        'stream_closed': '事件连接结束',
        'stream_access_revoked': '事件连接访问资格失效',
      }[value] ??
      '未识别结果';

  String kind(Object? value) =>
      const {
        'api_request': 'API 请求',
        'static_denied': '被拒资源请求',
        'stream_end': '事件连接结束',
      }[value] ??
      '请求记录';

  String shown(Object? value, String empty) =>
      value == null || value == '' ? empty : '$value';

  bool blocked(Json event) =>
      (event['status'] is num && event['status'] >= 400) ||
      !const {'allowed', 'stream_closed'}.contains(event['decision']);
  String timestamp(Object? raw) {
    final time = DateTime.tryParse('$raw')?.toLocal();
    if (time == null) return shown(raw, '—');
    String two(int n) => '$n'.padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  Widget badge(String text, Color color, {IconData? icon}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
        ],
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
  Widget details(Json event) => Container(
    color: const Color(0xfff7f9fb),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
    child: SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('来源 IP：${event['ip']} · 通道：${shown(event['channel'], '未解析')}'),
          const SizedBox(height: 8),
          Text('已认证账号 ID：${shown(event['user_id'], '未认证或未解析')}'),
          const SizedBox(height: 8),
          Text('当时人工归属标签：${shown(event['owner_label'], '未标注')}'),
          Text('当时人工关联账号 ID：${shown(event['owner_user_id'], '未关联')}（不代表认证身份）'),
          const SizedBox(height: 8),
          Text('当时匹配规则 ID：${shown(event['rule_id'], '无')}'),
          Text(
            '${kind(event['kind'])} · ${shown(event['method'], '未知方法')} ${shown(event['route'], '未知路径模板')}',
          ),
        ],
      ),
    ),
  );
  Widget record(Json event, bool wide) {
    final open = expanded == event['seq'], denied = blocked(event);
    final color = denied ? const Color(0xffa34c36) : const Color(0xff32786a);
    Widget cell(String text, int flex, {bool mono = false}) => Expanded(
      flex: flex,
      child: Tooltip(
        message: text,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: const Color(0xff35495b),
            fontFamily: mono ? 'monospace' : null,
          ),
        ),
      ),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xffe4e9ef))),
      ),
      child: Column(
        children: [
          InkWell(
            key: ValueKey('access-event-${event['seq']}'),
            onTap: () =>
                setState(() => expanded = open ? null : event['seq'] as int?),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: wide
                  ? Row(
                      children: [
                        cell(timestamp(event['at']), 3),
                        const SizedBox(width: 12),
                        cell(shown(event['ip'], '—'), 3, mono: true),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 150,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: badge(decision(event['decision']), color),
                          ),
                        ),
                        cell(
                          '${shown(event['method'], '—')} ${shown(event['route'], '—')}',
                          5,
                        ),
                        const SizedBox(width: 12),
                        cell(shown(event['channel'], '未解析'), 2),
                        SizedBox(
                          width: 52,
                          child: Text(
                            '${event['status'] ?? '—'}',
                            style: TextStyle(color: color, fontSize: 12),
                          ),
                        ),
                        Icon(
                          open ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: const Color(0xff7e8d9a),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            Text(
                              timestamp(event['at']),
                              style: const TextStyle(fontSize: 12),
                            ),
                            badge(
                              '${decision(event['decision'])} · ${event['status'] ?? '—'}',
                              color,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          shown(event['ip'], '—'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${shown(event['method'], '—')} ${shown(event['route'], '—')}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff657789),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: Icon(
                            open ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          if (open) details(event),
        ],
      ),
    );
  }

  Widget serviceDetails() => SecurityDetails(
    children: [
      const Text('网络请求记录（含内网与公网），不等于页面浏览证明，正常资源请求不记录。'),
      Text(
        scope == 'self'
            ? '当前范围：本账号已认证的访问记录；未登录拦截由管理员核对。'
            : '当前范围：全部网络请求记录，含白名单、设备、攻击防护与封禁拦截。',
      ),
      const Text('仅服务器生成的 API 请求、被拒静态请求和事件连接结束记录；异步队列与保留上限可能造成缺口，不是全量审计。'),
      const Text('保留策略固定为 14 天 / 最多 100000 条；本页最多显示 500 条，不提供清空或修改保留策略。'),
      if (status != null && scope == 'all') ...[
        Text(
          '排队 ${status!['queue_depth'] ?? '—'} · 已丢弃 ${status!['dropped'] ?? '—'} · 写入失败 ${status!['write_failures'] ?? '—'}',
        ),
        Text('最近写入：${shown(status!['last_write_at'], '暂无可用时间')}'),
        if (status!['last_error'] != null && status!['last_error'] != '')
          const Text('记录服务报告写入异常；可能存在未保存的请求。'),
      ],
    ],
  );
  @override
  Widget build(BuildContext context) {
    final keyword = search.trim().toLowerCase();
    final filtered = events
        .where(
          (e) =>
              (outcome == 'all' || (outcome == 'blocked') == blocked(e)) &&
              (channel.isEmpty || e['channel'] == channel) &&
              (keyword.isEmpty ||
                  [
                    'ip',
                    'route',
                    'method',
                    'user_id',
                    'owner_label',
                    'owner_user_id',
                  ].any(
                    (k) => '${e[k] ?? ''}'.toLowerCase().contains(keyword),
                  )),
        )
        .toList();
    final channels =
        events
            .map((e) => '${e['channel'] ?? ''}')
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return SecuritySurface(
      child: SizedBox(
        width: 1180,
        height: 760,
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(20, 16, 14, 14),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(bottom: BorderSide(color: Color(0xffdce4eb))),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xffeaf0f6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.history_rounded,
                        color: Color(0xff416487),
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '拦截与访问记录',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Color(0xff243d52),
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            '查看请求结果，追踪访问来源',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xff748494),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!SecurityPageScope.isRoot(context))
                      IconButton(
                        tooltip: '关闭请求记录',
                        onPressed: () {
                          if (closing) return;
                          closing = true;
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.close, size: 20),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        badge(
                          '当前显示 ${events.length} 条',
                          const Color(0xff456783),
                          icon: Icons.list_alt,
                        ),
                        badge(
                          '拦截 / 异常 ${events.where(blocked).length}',
                          const Color(0xffa34c36),
                          icon: Icons.shield_outlined,
                        ),
                        badge(
                          status == null
                              ? '记录服务状态尚未确认'
                              : status!['enabled'] == true
                              ? '本地记录器已就绪（不保证记录完整）'
                              : '本地记录器未就绪或不可用',
                          const Color(0xff657789),
                        ),
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => showService = !showService),
                          icon: Icon(
                            showService
                                ? Icons.expand_less
                                : Icons.info_outline,
                            size: 16,
                          ),
                          label: const Text('记录说明与服务状态'),
                        ),
                      ],
                    ),
                    if (status != null && error != null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '以下服务状态来自上次成功响应，当前状态尚未确认。',
                          style: TextStyle(
                            color: Color(0xffa34c36),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    if (showService)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: serviceDetails(),
                      ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: box.maxWidth < 550 ? box.maxWidth - 32 : 300,
                          child: TextField(
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search, size: 18),
                              hintText: '筛选已加载记录：IP / 账号 / 路径',
                              isDense: true,
                            ),
                            onChanged: (v) => setState(() => search = v),
                          ),
                        ),
                        SizedBox(
                          width: 140,
                          child: DropdownButtonFormField<String>(
                            initialValue: outcome,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '结果',
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'all',
                                child: Text('全部结果'),
                              ),
                              DropdownMenuItem(
                                value: 'blocked',
                                child: Text('拦截 / 异常'),
                              ),
                              DropdownMenuItem(
                                value: 'allowed',
                                child: Text('允许 / 结束'),
                              ),
                            ],
                            onChanged: (v) => setState(() => outcome = v!),
                          ),
                        ),
                        SizedBox(
                          width: 165,
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('$channel-${channels.join()}'),
                            initialValue: channels.contains(channel)
                                ? channel
                                : '',
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '通道',
                              isDense: true,
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('全部通道'),
                              ),
                              for (final c in channels)
                                DropdownMenuItem(
                                  value: c,
                                  child: Text(
                                    c,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (v) => setState(() => channel = v ?? ''),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: busy ? null : () => load(reset: true),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('刷新记录'),
                        ),
                      ],
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (busy) const LinearProgressIndicator(minHeight: 2),
                    if (search.isNotEmpty ||
                        outcome != 'all' ||
                        channel.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '匹配 ${filtered.length} / 已加载 ${events.length} 条',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff657789),
                          ),
                        ),
                      ),
                    if (box.maxWidth >= 950)
                      Container(
                        color: const Color(0xffeaf0f5),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        child: const Row(
                          children: [
                            Expanded(flex: 3, child: Text('时间')),
                            SizedBox(width: 12),
                            Expanded(flex: 3, child: Text('来源 IP')),
                            SizedBox(width: 12),
                            SizedBox(width: 150, child: Text('请求结果')),
                            Expanded(flex: 5, child: Text('请求路径')),
                            SizedBox(width: 12),
                            Expanded(flex: 2, child: Text('通道')),
                            SizedBox(width: 70, child: Text('状态')),
                          ],
                        ),
                      ),
                    for (final event in filtered)
                      record(event, box.maxWidth >= 950),
                    if (loaded && !busy && error == null && events.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: Text('当前查询没有记录；不代表没有访问或拒绝事件。')),
                      ),
                    if (events.isNotEmpty && filtered.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: Text('已加载记录中没有匹配项')),
                      ),
                    const SizedBox(height: 14),
                    if (loaded && events.length >= maximum)
                      const Text(
                        '已达本页 500 条上限；更早记录未展示。刷新可重新查看最新记录。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xff748494),
                        ),
                      )
                    else if (loaded && before != 0)
                      Align(
                        alignment: Alignment.center,
                        child: OutlinedButton(
                          onPressed: busy ? null : () => load(),
                          child: const Text('加载更早'),
                        ),
                      )
                    else if (loaded && events.isNotEmpty && error == null)
                      const Text(
                        '当前查询范围已无更早记录；不表示记录完整。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xff748494),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
