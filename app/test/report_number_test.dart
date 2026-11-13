import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/report_number.dart';

void main() {
  test('SQL trailing precision obeys selected report decimals', () {
    const heat = '3037.000000000000000000';
    expect(reportNumber(heat, 2), '3037.00');
    expect(reportNumber(heat, 0), '3037');
    expect(reportNumber(heat, 6), '3037.000000');
    expect(heat, '3037.000000000000000000');
  });
  test('rounds exact decimals without losing large integer digits', () {
    expect(
      reportNumber('12345678901234567890.12345678', 2),
      '12345678901234567890.12',
    );
    expect(
      reportNumber('99999999999999999999.995', 2),
      '100000000000000000000.00',
    );
    expect(reportNumber('2.675', 2), '2.68');
    expect(reportNumber('-2.675', 2), '-2.68');
    expect(reportNumber('-0.0001', 2), '0.00');
    expect(reportNumber('1.255e2', 0), '126');
    expect(reportNumber(1e-7, 6), '0.000000');
  });
  test('missing, zero and text keep distinct meanings', () {
    expect(reportNumber(null, 2), '—');
    expect(reportNumber('0.000000000000000000', 2), '0.00');
    expect(reportNumber('未采样', 2), '未采样');
    expect(reportNumber(12, 2), '12.00');
  });
}
