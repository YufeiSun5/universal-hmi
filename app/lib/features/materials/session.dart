import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../platform/process_files.dart';
import '../../platform/material_unload.dart';
import '../../shared/api.dart';

const materialsBase = '/api/v1/materials';
String materialOperationID() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
String materialText(Json data, String key) => data[key]?.toString() ?? '';
String materialStatus(String status) =>
    const {
      'pending': '待审批',
      'approved': '已通过',
      'rejected': '已驳回',
      'confirmed': '已确认',
      'not_returned': '未退库',
      'part_returned': '部分退库',
      'returned': '全部退库',
    }[status] ??
    status;
String materialKind(String kind) =>
    const {
      'inbound': '入库',
      'outbound': '出库',
      'return': '退库',
      'transfer': '转类',
    }[kind] ??
    kind;
String materialTime(Object? value) {
  final date = DateTime.tryParse('$value');
  if (date == null) return value?.toString() ?? '';
  return date.toUtc().add(const Duration(hours: 8)).toString().substring(0, 19);
}

class MaterialImageDraft {
  MaterialImageDraft(this.file);
  final ProcessFile file;
  final operation = materialOperationID();
  String? assetID, error;
  bool uploading = false;
}

/// Owned by the authenticated workspace, so navigation retains drafts without
/// persisting credentials or pending stock commands to disk/localStorage.
class MaterialsSession extends ChangeNotifier {
  MaterialsSession() {
    _removeUnload = watchMaterialUnload(() => dirty);
  }
  late final void Function() _removeUnload;
  String section = 'applications';
  bool directoryHidden = false;
  VoidCallback? openAccount;
  final drafts = <String, MaterialDraft>{};
  final filters = <String, Json>{};
  final offsets = <String, double>{};
  final categoryExpanded = <String>{};
  final categorySeen = <String>{};
  bool categoryDefaultExpanded = true;
  Json? selectedCategory;
  bool get dirty => drafts.values.any((d) => d.dirty || d.pending != null);
  MaterialDraft draft(String key) =>
      drafts.putIfAbsent(key, () => MaterialDraft(onChanged: notifyListeners));
  void clear(String key) {
    drafts.remove(key);
    notifyListeners();
  }

  @override
  void dispose() {
    _removeUnload();
    super.dispose();
  }
}

class MaterialDraft {
  MaterialDraft({required this.onChanged});
  final VoidCallback onChanged;
  Json values = {};
  List<Json> lines = [];
  final images = <MaterialImageDraft>[];
  bool dirty = false;
  Json? pending;
  String? pendingPath;
  bool busy = false;
  void changed() {
    dirty = true;
    onChanged();
  }

  void set(String key, Object? value) {
    values[key] = value;
    changed();
  }

  void clear() {
    values = {};
    lines = [];
    images.clear();
    dirty = false;
    pending = null;
    pendingPath = null;
    onChanged();
  }

  /// A transport failure leaves the exact command frozen for a same-ID retry.
  /// Definite business rejection unlocks editing; it never means success.
  Future<Json> submit(PlatformApi api, String path, Json payload) async {
    if (busy) throw StateError('正在提交，请稍候');
    if (pending != null && pendingPath != path) throw StateError('请先确认上一笔操作结果');
    pending ??=
        jsonDecode(
              jsonEncode({...payload, 'operation_id': materialOperationID()}),
            )
            as Json;
    pendingPath = path;
    busy = true;
    onChanged();
    try {
      final result = await api.request('POST', path, body: pending);
      clear();
      return result;
    } on PlatformRequestException catch (e) {
      if (e.statusCode >= 400 &&
          e.statusCode < 500 &&
          e.statusCode != 408 &&
          e.statusCode != 429) {
        pending = null;
        pendingPath = null;
      }
      rethrow;
    } finally {
      busy = false;
      onChanged();
    }
  }
}
