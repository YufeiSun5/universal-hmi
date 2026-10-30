import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/equipment/workspace.dart';
import 'package:universal_hmi/features/equipment/editor.dart';
import 'package:universal_hmi/features/equipment/live_status.dart';
import 'package:universal_hmi/features/equipment/navigation.dart';
import 'package:universal_hmi/shared/api.dart';

class LedgerApi implements PlatformApi {
  Json device = {
    'id': 'pump',
    'revision': 1,
    'name': '一号循环泵',
    'code': 'P-001',
    'station': '城北站区',
    'site': '学府小站',
    'category': '水泵',
    'status': 'active',
    'model': 'TEST-100',
    'properties': <Json>[],
    'photos': <Json>[],
  };
  final queries = <Json>[];
  Json? saved;
  bool failSave = false;
  final statusCalls = <Completer<Json>>[];
  bool deferredStatus = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/equipment/status') {
      if (deferredStatus) {
        final c = Completer<Json>();
        statusCalls.add(c);
        return c.future;
      }
      return {
        'items': [
          {
            'id': 'pump',
            'revision': device['revision'],
            'state': 'unconfigured',
          },
        ],
      };
    }
    if (path == '/api/v1/points') {
      return {
        'items': [
          {
            'id': 'run',
            'station': '城北站区',
            'name': '运行电流',
            'data_type': 'FLOAT',
            'unit': 'A',
          },
        ],
      };
    }
    if (path == '/api/v1/stations') {
      return {
        'items': [
          {'name': '城北站区'},
        ],
      };
    }
    if (method == 'POST') {
      saved = Map<String, dynamic>.from(body as Map);
      if (failSave) throw const PlatformRequestException(409, '档案版本冲突');
      return {...saved!, 'id': 'pump', 'revision': 2};
    }
    if (path.endsWith('/pump')) return device;
    queries.add({...?query});
    return {
      'items': [device],
      'total': 1,
      'counts': {'all': 1, 'active': 1},
      'categories': ['水泵'],
      'places': [
        {'station': '城北站区', 'site': '学府小站', 'count': 1},
      ],
    };
  }

  @override
  void close() {}
  @override
  Future<Uint8List> download(String id) => throw UnimplementedError();
  @override
  Future<Json> upload(String name, Uint8List bytes) =>
      throw UnimplementedError();
}

class PhotoApi extends LedgerApi {
  int requests = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.contains('/photos/')) {
      requests++;
      return {
        'data':
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=',
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

class NavigationApi extends LedgerApi {
  Json? navigationSaved;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/equipment-navigation') {
      if (method == 'PUT') {
        navigationSaved = Map<String, dynamic>.from(body as Map);
        return {'revision': 8};
      }
      return {
        'revision': 7,
        'nodes': <Json>[
          {
            'id': 'g',
            'label': '原分组',
            'children': <Json>[
              {'id': 'a', 'label': '原菜单', 'station': '城北站区', 'site': '学府小站'},
            ],
          },
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

class RevisionApi extends LedgerApi {
  int detailRevision = 2;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/equipment/pump') {
      return {...device, 'revision': detailRevision};
    }
    if (path == '/api/v1/equipment/status') {
      return {
        'items': [
          {'id': 'pump', 'revision': detailRevision, 'state': 'stopped'},
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets('navigation editor saves changed label with revision', (t) async {
    final api = NavigationApi();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EquipmentNavigationEditor(
            api: api,
            stations: const ['城北站区'],
            places: const [],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('原分组'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, '新分组');
    await t.tap(find.text('确定'));
    await t.pumpAndSettle(const Duration(milliseconds: 300));
    await t.tap(find.text('保存菜单'));
    await t.pumpAndSettle();
    expect(api.navigationSaved?['revision'], 7);
    expect((api.navigationSaved?['nodes'] as List).first['label'], '新分组');
  });
  testWidgets('opening and refreshing synchronize list and detail revisions', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final api = RevisionApi();
    await t.pumpWidget(
      MaterialApp(home: EquipmentWorkspace(api: api, canEdit: false)),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('一号循环泵').first);
    await t.pumpAndSettle();
    expect(find.text('停止'), findsNWidgets(2));
    api.detailRevision = 3;
    await t.tap(find.byTooltip('刷新台账'));
    await t.pumpAndSettle();
    expect(find.text('停止'), findsNWidgets(2));
    expect(find.text('未知'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('photo mode rebuild caches bytes and API replacement refetches', (
    t,
  ) async {
    final a = PhotoApi(), b = PhotoApi();
    Widget view(PhotoApi api, String fit) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: EquipmentPhoto(
            api: api,
            deviceID: 'pump',
            photo: const {'id': 'p'},
            fit: fit,
          ),
        ),
      ),
    );
    await t.pumpWidget(view(a, 'contain'));
    await t.pump();
    expect(a.requests, 1);
    final originalProvider = t.widget<Image>(find.byType(Image)).image;
    await t.pumpWidget(view(a, 'cover'));
    await t.pump();
    expect(a.requests, 1);
    expect(t.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
    expect(t.widget<Image>(find.byType(Image)).image, originalProvider);
    for (var frame = 0; frame < 8; frame++) {
      await t.pumpWidget(view(a, 'cover'));
      await t.pump(const Duration(seconds: 2));
      expect(t.widget<Image>(find.byType(Image)).image, originalProvider);
    }
    expect(a.requests, 1);
    await t.pumpWidget(view(b, 'fill'));
    await t.pump();
    expect(b.requests, 1);
    expect(t.widget<Image>(find.byType(Image)).fit, BoxFit.fill);
  });
  testWidgets(
    'equipment navigation expands, searches and opens station target',
    (t) async {
      var opened = '';
      const nodes = <Json>[
        {
          'id': 'g',
          'label': '北区',
          'children': <Json>[
            {'id': 'a', 'label': '学府', 'station': '城北站区', 'site': '学府小站'},
          ],
        },
      ];
      Widget view(String query) => MaterialApp(
        home: Scaffold(
          body: EquipmentNavigation(
            nodes: nodes,
            station: '',
            site: '',
            query: query,
            onOpen: (station, site) => opened = '$station/$site',
          ),
        ),
      );
      await t.pumpWidget(view(''));
      await t.tap(find.text('学府'));
      expect(opened, '城北站区/学府小站');
      await t.tap(find.byTooltip('折叠菜单'));
      await t.pump();
      expect(find.text('学府'), findsNothing);
      await t.pumpWidget(view('学府'));
      expect(find.text('学府'), findsOneWidget);
    },
  );
  testWidgets('short runtime viewport can scroll to and open equipment', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(600, 600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const SizedBox(height: 180),
              Expanded(
                child: EquipmentWorkspace(api: LedgerApi(), canEdit: false),
              ),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.drag(
      find.byKey(const Key('equipment-compact-scroll')),
      const Offset(0, -250),
    );
    await t.pumpAndSettle();
    expect(find.text('一号循环泵').hitTestable(), findsOneWidget);
    await t.tap(find.text('一号循环泵'));
    await t.pumpAndSettle();
    expect(find.text('设备档案'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'status discards late pages, revision mismatch and connection failure',
    (t) async {
      final api = LedgerApi()..deferredStatus = true;
      final live = EquipmentLiveStatus(api);
      final d = api.device;
      live.select([d]);
      live.select([
        {...d, 'revision': 2},
      ]);
      api.statusCalls[1].complete({
        'items': [
          {'id': 'pump', 'revision': 2, 'state': 'fault'},
        ],
      });
      await t.pump();
      api.statusCalls[0].complete({
        'items': [
          {'id': 'pump', 'revision': 1, 'state': 'running'},
        ],
      });
      await t.pump();
      expect(live.status({...d, 'revision': 2})['state'], 'fault');
      expect(live.status(d)['state'], 'unknown');
      await t.pump(const Duration(seconds: 2));
      api.statusCalls[2].completeError(Exception('network disconnected'));
      await t.pump();
      expect(live.status({...d, 'revision': 2})['state'], 'offline');
      live.dispose();
    },
  );
  testWidgets('developer chooses variable and saves simple condition', (
    t,
  ) async {
    final api = LedgerApi()..failSave = true;
    await t.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EquipmentEditor(
            api: api,
            stations: const ['城北站区'],
            device: api.device,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('equipment-bind-running')));
    await t.tap(find.byKey(const Key('equipment-bind-running')));
    await t.pumpAndSettle();
    await t.tap(find.text('城北站区 / 运行电流'));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const Key('equipment-expression-running')),
      'x >= 0.5 && x <= 100',
    );
    await t.tap(find.byKey(const Key('equipment-save')));
    await t.pumpAndSettle();
    expect(api.saved?['signals']['running']['point_id'], 'run');
    expect(
      api.saved?['signals']['running']['expression'],
      'x >= 0.5 && x <= 100',
    );
    expect(api.saved?['signals']['fault'], isNull);
    expect(find.text('档案版本冲突'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'ledger read-only scope navigation and narrow detail remain usable',
    (t) async {
      final api = LedgerApi();
      await t.binding.setSurfaceSize(const Size(1400, 850));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(home: EquipmentWorkspace(api: api, canEdit: false)),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('equipment-add')), findsNothing);
      expect(find.text('在用'), findsNothing);
      expect(find.text('检修'), findsNothing);
      expect(find.text('登记设备 1   ·   所属站区 1   ·   设备类别 1'), findsOneWidget);
      await t.tap(find.text('学府小站').first);
      await t.pumpAndSettle();
      expect(api.queries.last['station'], '城北站区');
      expect(api.queries.last['site'], '学府小站');
      await t.tap(find.text('一号循环泵'));
      await t.pumpAndSettle();
      expect(find.text('设备档案'), findsOneWidget);
      expect(find.text('上传图片'), findsNothing);
      await t.binding.setSurfaceSize(const Size(390, 720));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('一号循环泵'));
      await t.pumpAndSettle();
      expect(find.text('设备档案'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    },
  );
  testWidgets('search is debounced and sends server filter', (t) async {
    final api = LedgerApi();
    await t.pumpWidget(
      MaterialApp(home: EquipmentWorkspace(api: api, canEdit: true)),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('equipment-search')), 'P-001');
    await t.pump(const Duration(milliseconds: 350));
    await t.pumpAndSettle();
    expect(api.queries.last['search'], 'P-001');
    expect(api.queries.last['offset'], 0);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('save conflict retains draft and original revision', (t) async {
    final api = LedgerApi()..failSave = true;
    await t.binding.setSurfaceSize(const Size(1000, 950));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EquipmentEditor(
            api: api,
            stations: const ['城北站区'],
            device: api.device,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('equipment-field-name')), '修改后名称');
    expect(find.text('档案状态'), findsNothing);
    await t.tap(find.byKey(const Key('equipment-save')));
    await t.pumpAndSettle();
    expect(find.text('档案版本冲突'), findsOneWidget);
    expect(find.text('修改后名称'), findsOneWidget);
    expect(api.saved?['revision'], 1);
    expect(api.saved?['site'], '学府小站');
    expect(t.takeException(), isNull);
  });
  testWidgets('required equipment fields prevent empty saves', (t) async {
    final api = LedgerApi();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EquipmentEditor(api: api, stations: const ['城北站区']),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('equipment-save')));
    await t.pumpAndSettle();
    expect(api.saved, isNull);
    expect(find.text('请选择站区'), findsOneWidget);
    expect(find.text('请填写设备名称'), findsOneWidget);
  });
}
