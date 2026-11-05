import 'dart:async';
import 'package:flutter/foundation.dart';
import 'backend_management_stub.dart'
    if (dart.library.io) 'backend_management_native.dart'
    as native;

bool get backendManagementAvailable => native.backendManagementAvailable;

class BackendManagement extends ChangeNotifier {
  Map<String, dynamic>? state;
  bool busy = false;
  Future<void> run(String action) async {
    if (busy) return;
    busy = true;
    state = {'phase': 'preparing', 'message': '正在核对工程后台'};
    notifyListeners();
    try {
      await native.manageBackend(action, (value) {
        state = value;
        notifyListeners();
      });
    } catch (e) {
      state = {
        'phase': 'failed',
        'message': '$e',
        'error_code': 'management_failed',
      };
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void dismiss() {
    if (!busy) {
      state = null;
      notifyListeners();
    }
  }
}

final backendManagement = BackendManagement();
