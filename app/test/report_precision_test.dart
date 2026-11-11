import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/statistics.dart';
import 'package:universal_hmi/shared/table.dart';
import 'energy_statistics_test.dart' show EnergyApi;

void main() {
  for (final kind in ['monthly', 'season']) {
    testWidgets('$kind heat obeys precision without replacing stored values', (
      t,
    ) async {
      final api = EnergyApi()
        ..savedScreen = {'id': 'daily', 'kind': 'daily', 'revision': 1}
        ..readings = [
          for (final metric in ['heat', 'electricity', 'water'])
            {
              'station': '01-001',
              'name': '中心站东南区',
              'date': '2026–2027采暖季',
              'metric': metric,
              'label': metric,
              'unit': metric == 'heat'
                  ? 'GJ'
                  : metric == 'water'
                  ? 't'
                  : 'kWh',
              'day_usage': metric == 'heat'
                  ? '3037.000000000000000000'
                  : metric == 'water'
                  ? null
                  : '0.0000000000000000',
            },
        ];
      final catalog = ExternalCatalog(api, canDevelop: false)
        ..screens = [api.savedScreen];
      final screen = catalog.historyScreens.firstWhere(
        (s) => s['kind'] == kind,
      );
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatisticsQuery(api: api, screen: screen),
          ),
        ),
      );
      await t.pumpAndSettle();
      List<String> cells() =>
          t.widget<DenseTable>(find.byType(DenseTable)).rowBuilder!(0);
      expect(cells(), containsAll(['3037.00', '0.00', '—']));
      final queries = api.queryCount;
      await t.tap(find.byType(DropdownButtonFormField<int>));
      await t.pumpAndSettle();
      await t.tap(find.text('0').last);
      await t.pumpAndSettle();
      expect(cells(), containsAll(['3037', '0', '—']));
      await t.tap(find.byType(DropdownButtonFormField<int>));
      await t.pumpAndSettle();
      await t.tap(find.text('4').last);
      await t.pumpAndSettle();
      expect(cells(), containsAll(['3037.0000', '0.0000', '—']));
      expect(api.queryCount, queries);
      expect(api.readings!.first['day_usage'], '3037.000000000000000000');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      catalog.dispose();
    });
  }
}
