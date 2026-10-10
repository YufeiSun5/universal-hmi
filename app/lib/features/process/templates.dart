import 'dart:convert';
import 'package:flutter/services.dart';
import '../../shared/api.dart';
import 'model.dart';

class ProcessTemplates {
  static Json? _heating;
  static Future<ScreenDocument> heatingStation(String station) async {
    final json = _heating ??=
        jsonDecode(
              await rootBundle.loadString(
                'assets/process/templates/heating-station.json',
                cache: false,
              ),
            )
            as Json;
    return ScreenDocument.fromJson(json).instantiate(station, suffix: '');
  }
}
