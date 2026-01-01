import 'package:decimal/decimal.dart';

/// Centralized utility for token unit conversions in swap_aggregator.
///
/// Note: This is a copy of the logic in multi_chain_wallet_core
/// to keep swap_aggregator independent while maintaining consistency.
class UnitUtils {
  /// Converts token amount (Decimal) to smallest unit (BigInt).
  static BigInt toTokenUnit(Decimal amount, int decimals) {
    if (decimals == 0) return amount.toBigInt();
    final multiplier = Decimal.parse('10').pow(decimals).toDecimal();
    return (amount * multiplier).toBigInt();
  }

  /// Converts from smallest unit (BigInt) to token amount (Decimal).
  static Decimal fromTokenUnit(BigInt value, int decimals) {
    if (decimals == 0) return Decimal.fromBigInt(value);
    final divisor = Decimal.parse('10').pow(decimals).toDecimal();
    return (Decimal.fromBigInt(value) / divisor).toDecimal();
  }
}
