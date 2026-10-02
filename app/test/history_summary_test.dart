import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/history_summary.dart';

void main() {
  test(
    'Page summaries exclude invalid values and keep frozen units separate',
    () {
      final rows = summarizeHistoryPage([
        {
          'point_id': 'p',
          'unit': 'C',
          'value': 10,
          'quality': 'good',
          'source_time': '2026-10-02T00:00:00Z',
        },
        {
          'point_id': 'p',
          'unit': 'C',
          'value': 90,
          'quality': 'bad',
          'source_time': '2026-10-02T00:00:01Z',
        },
        {
          'point_id': 'p',
          'unit': 'C',
          'value': 20,
          'quality': 'imported',
          'source_time': '2026-10-02T00:00:02Z',
        },
        {
          'point_id': 'p',
          'unit': 'F',
          'value': 68,
          'quality': 'good',
          'source_time': '2026-10-02T00:00:03Z',
        },
      ]);
      expect(rows, hasLength(2));
      expect(rows.first['count'], 3);
      expect(rows.first['valid'], 2);
      expect(rows.first['mean'], 15);
      expect(rows.first['latest'], 20);
      expect(rows.last['unit'], 'F');
      expect(rows.last['mean'], 68);
    },
  );
}
