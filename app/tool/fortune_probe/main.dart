// Standalone fixture: no production bootstrap, backend, identity, or data.
import 'dart:async';
import 'package:flutter/material.dart';
import 'bridge.dart';
import 'view.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'HmiCJK',
      colorSchemeSeed: const Color(0xff465f71),
    ),
    home: const ProbePage(),
  );
}

class ProbePage extends StatefulWidget {
  const ProbePage({super.key});
  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  final bridge = ProbeBridge();
  late final StreamSubscription<Map<String, dynamic>> subscription;
  String status = '正在连接表格…';
  int changes = 0, operations = 0;
  bool connected = false;
  dynamic saved;
  final checks = <String>[];

  @override
  void initState() {
    super.initState();
    subscription = bridge.events.stream.listen((event) {
      if (event['type'] == 'ready' && !connected) {
        connected = true;
        unawaited(verify());
      } else if (event['type'] == 'changed' || event['type'] == 'ops') {
        if (mounted) {
          setState(() {
            if (event['type'] == 'changed') changes++;
            if (event['type'] == 'ops') {
              operations += (event['ops'] as List).length;
            }
          });
        }
      }
    });
  }

  List<Map<String, dynamic>> fixture() => [
    {
      'id': 'probe-sheet',
      'name': '接入验证',
      'order': 0,
      'status': 1,
      'row': 50,
      'column': 12,
      'luckysheet_select_save': [
        {
          'row': [0, 0],
          'column': [0, 0],
        },
      ],
      'calcChain': [
        {'r': 1, 'c': 2, 'id': 'probe-sheet'},
      ],
      'celldata': [
        {
          'r': 0,
          'c': 0,
          'v': {'v': '站区', 'bg': '#dce3e8', 'bl': 1},
        },
        {
          'r': 0,
          'c': 1,
          'v': {'v': '输入值', 'bg': '#dce3e8', 'bl': 1},
        },
        {
          'r': 0,
          'c': 2,
          'v': {'v': '公式 × 2', 'bg': '#dce3e8', 'bl': 1},
        },
        {
          'r': 1,
          'c': 0,
          'v': {'v': '隔离样例'},
        },
        {
          'r': 1,
          'c': 1,
          'v': {'v': 10},
        },
        {
          'r': 1,
          'c': 2,
          'v': {'f': '=B2*2', 'v': 20},
        },
      ],
      'config': {
        'columnlen': {'0': 160, '1': 140, '2': 180},
      },
    },
  ];

  Future<void> verify() async {
    try {
      await bridge.request('load', {'sheets': fixture()});
      checks.add('flutter-to-sheet-load');
      await bridge.request('set', {'row': 1, 'column': 1, 'value': 42});
      // React commits asynchronously; poll the public snapshot, bounded to 5s.
      dynamic snapshot;
      for (var i = 0; i < 50; i++) {
        snapshot = await bridge.request('snapshot');
        if (snapshot[0]['data'][1][2]?['v'] == 84) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (snapshot[0]['data'][1][1]['v'] != 42 ||
          snapshot[0]['data'][1][2]['v'] != 84) {
        throw StateError(
          'Expected B2=42, C2=84; got ${snapshot[0]['data'][1]}',
        );
      }
      checks.addAll([
        'flutter-to-sheet-write',
        'formula-recalculation',
        'sheet-to-flutter-snapshot',
      ]);
      saved = snapshot;
      await bridge.request('load', {'sheets': saved});
      final restored = await bridge.request('snapshot');
      if (restored[0]['data'][1][1]['v'] != 42 ||
          restored[0]['data'][1][2]['f'] != '=B2*2') {
        throw StateError('Snapshot round trip failed');
      }
      checks.add('snapshot-reload');
      await writeReport({
        'passed': true,
        'checks': checks,
        'changes': changes,
        'operations': operations,
        'b2': restored[0]['data'][1][1]['v'],
        'c2': restored[0]['data'][1][2]['v'],
      });
      if (mounted) setState(() => status = '接入检查通过 · B2=42，C2=84 · 可继续编辑');
    } catch (e) {
      await writeReport({
        'passed': false,
        'checks': checks,
        'error': e.toString(),
      });
      if (mounted) setState(() => status = '检查失败：$e');
    }
  }

  Future<void> capture() async {
    try {
      saved = await bridge.request('snapshot');
      if (mounted) {
        setState(
          () => status =
              '已读取到 Flutter 内存 · B2=${saved[0]['data'][1][1]['v']}，C2=${saved[0]['data'][1][2]['v']}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    }
  }

  Future<void> restore() async {
    try {
      await bridge.request('load', {'sheets': saved});
      if (mounted) setState(() => status = '已重新加载 Flutter 内存快照');
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    }
  }

  @override
  void dispose() {
    subscription.cancel();
    bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xffe9ecef),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Flutter × FortuneSheet',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const Text('独立技术验证 · 合成数据'),
                OutlinedButton(
                  onPressed: connected ? capture : null,
                  child: const Text('读取快照'),
                ),
                OutlinedButton(
                  onPressed: saved != null ? restore : null,
                  child: const Text('重新加载'),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ProbeView(bridge: bridge),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('$status  |  变更 $changes / 操作 $operations'),
          ),
        ],
      ),
    ),
  );
}
