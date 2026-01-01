import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swap_aggregator/src/utils/unit_utils.dart';

void main() {
  group('UnitUtils', () {
    test('toTokenUnit converts correctly', () {
      expect(UnitUtils.toTokenUnit(Decimal.parse('1'), 18),
          BigInt.from(10).pow(18));
      expect(
          UnitUtils.toTokenUnit(Decimal.parse('1'), 6), BigInt.from(1000000));
      expect(
          UnitUtils.toTokenUnit(Decimal.parse('1.5'), 6), BigInt.from(1500000));
    });

    test('fromTokenUnit converts correctly', () {
      expect(UnitUtils.fromTokenUnit(BigInt.from(10).pow(18), 18),
          Decimal.parse('1'));
      expect(
          UnitUtils.fromTokenUnit(BigInt.from(1000000), 6), Decimal.parse('1'));
      expect(UnitUtils.fromTokenUnit(BigInt.from(1500000), 6),
          Decimal.parse('1.5'));
    });
  });
}
