import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/history_summary.dart';

void main() {
  test('Manual history dates reject silent calendar/time normalization', () {
    for (final invalid in [
      '2026-02-30 10:00:00',
      '2026-13-01',
      '2026-10-01 24:00:00',
      '2026-10-01 12:60:00',
      '2026-10-01T12:00:00+00:99',
    ]) {
      expect(parseHistoryTime(invalid), isNull, reason: invalid);
    }
    expect(
      parseHistoryTime('2024-02-29 10:30:00'),
      DateTime(2024, 2, 29, 10, 30),
    );
    expect(
      parseHistoryTime('2026-10-02T12:30:00+08:00')!.toUtc(),
      DateTime.utc(2026, 10, 2, 4, 30),
    );
  });

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
