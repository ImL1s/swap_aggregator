import 'package:decimal/decimal.dart';

import '../core/models/swap_quote.dart';

/// Comparator for sorting and selecting swap quotes
class QuoteComparator {
  /// Sort quotes by best output amount and gas costs
  static List<SwapQuote> sortQuotes(
    List<SwapQuote> quotes, {
    bool considerGas = true,
  }) {
    if (quotes.isEmpty) return [];

    final sorted = List<SwapQuote>.from(quotes);

    sorted.sort((a, b) {
      if (considerGas) {
        // Compare effective rates (output - gas cost)
        // Note: This assumes gas cost is available and normalized to output token
        // If gas cost in output token is 0, it falls back to raw output amount
        final rateA = a.effectiveRate;
        final rateB = b.effectiveRate;
        if (rateA != rateB) {
          return rateB.compareTo(rateA); // Higher effective rate is better
        }
      }

      // Fallback to raw output amount
      return b.outputAmount.compareTo(a.outputAmount);
    });

    return sorted;
  }

  /// Find the best quote from a list
  static SwapQuote? findBestQuote(
    List<SwapQuote> quotes, {
    bool considerGas = true,
  }) {
    final sorted = sortQuotes(quotes, considerGas: considerGas);
    return sorted.isNotEmpty ? sorted.first : null;
  }

  /// Filter out quotes with high price impact
  static List<SwapQuote> filterHighImpact(
    List<SwapQuote> quotes, {
    double maxImpact = 10.0,
  }) {
    return quotes.where((q) => q.priceImpact <= maxImpact).toList();
  }

  /// Filter out quotes with insufficient liquidity (zero output)
  static List<SwapQuote> filterValid(List<SwapQuote> quotes) {
    return quotes.where((q) => q.outputAmount > Decimal.zero).toList();
  }
}
