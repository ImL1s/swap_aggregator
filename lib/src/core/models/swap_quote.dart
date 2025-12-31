import 'package:decimal/decimal.dart';
import 'package:equatable/equatable.dart';

import 'gas_estimate.dart';
import 'swap_params.dart';

/// Represents a swap quote from a provider
///
/// Contains all information about the expected swap outcome,
/// including rates, fees, and routing information.
class SwapQuote extends Equatable {
  /// Provider/aggregator name (e.g., '1inch', 'ParaSwap')
  final String provider;

  /// Original swap parameters
  final SwapParams params;

  /// Input amount
  final Decimal inputAmount;

  /// Expected output amount
  final Decimal outputAmount;

  /// Minimum output amount after slippage
  final Decimal minimumOutputAmount;

  /// Exchange rate (outputAmount / inputAmount)
  final Decimal exchangeRate;

  /// Swap routes used
  final List<SwapRoute> routes;

  /// Gas estimation
  final GasEstimate gasEstimate;

  /// Price impact as percentage (e.g., 0.5 = 0.5%)
  final double priceImpact;

  /// Protocols used in the swap (e.g., ['Uniswap V3', 'Curve'])
  final List<String> protocols;

  /// Quote validity timestamp (Unix seconds)
  final int validUntil;

  /// Quote creation timestamp
  final DateTime timestamp;

  /// Raw response data from provider
  final Map<String, dynamic> metadata;

  /// Check if quote is still valid
  bool get isValid => DateTime.now().millisecondsSinceEpoch < validUntil * 1000;

  /// Get effective rate including gas
  Decimal get effectiveRate {
    if (inputAmount == Decimal.zero) return Decimal.zero;
    final netOutput = outputAmount - gasEstimate.estimatedCostInToken;
    return (netOutput / inputAmount).toDecimal();
  }

  /// Check if price impact is high (> 5%)
  bool get isHighPriceImpact => priceImpact > 5.0;

  /// Check if price impact is very high (> 10%)
  bool get isVeryHighPriceImpact => priceImpact > 10.0;

  const SwapQuote({
    required this.provider,
    required this.params,
    required this.inputAmount,
    required this.outputAmount,
    required this.minimumOutputAmount,
    required this.exchangeRate,
    required this.routes,
    required this.gasEstimate,
    required this.priceImpact,
    required this.protocols,
    required this.validUntil,
    required this.timestamp,
    required this.metadata,
  });

  /// Create a copy with modified fields
  SwapQuote copyWith({
    String? provider,
    SwapParams? params,
    Decimal? inputAmount,
    Decimal? outputAmount,
    Decimal? minimumOutputAmount,
    Decimal? exchangeRate,
    List<SwapRoute>? routes,
    GasEstimate? gasEstimate,
    double? priceImpact,
    List<String>? protocols,
    int? validUntil,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) {
    return SwapQuote(
      provider: provider ?? this.provider,
      params: params ?? this.params,
      inputAmount: inputAmount ?? this.inputAmount,
      outputAmount: outputAmount ?? this.outputAmount,
      minimumOutputAmount: minimumOutputAmount ?? this.minimumOutputAmount,
      exchangeRate: exchangeRate ?? this.exchangeRate,
      routes: routes ?? this.routes,
      gasEstimate: gasEstimate ?? this.gasEstimate,
      priceImpact: priceImpact ?? this.priceImpact,
      protocols: protocols ?? this.protocols,
      validUntil: validUntil ?? this.validUntil,
      timestamp: timestamp ?? this.timestamp,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  List<Object?> get props => [
        provider,
        inputAmount,
        outputAmount,
        minimumOutputAmount,
        exchangeRate,
        priceImpact,
        validUntil,
      ];

  @override
  String toString() =>
      'SwapQuote($provider: ${params.fromToken} → ${params.toToken}, '
      'rate: $exchangeRate, impact: ${priceImpact.toStringAsFixed(2)}%)';
}

/// Represents a swap route
class SwapRoute extends Equatable {
  /// Protocol name (e.g., 'Uniswap V3', 'Curve')
  final String protocol;

  /// Percentage of the total amount through this route (0-100)
  final double portion;

  /// Individual swap steps in this route
  final List<SwapStep> steps;

  const SwapRoute({
    required this.protocol,
    required this.portion,
    required this.steps,
  });

  @override
  List<Object?> get props => [protocol, portion, steps];
}

/// Represents a single step in a swap route
class SwapStep extends Equatable {
  /// Source token address
  final String fromToken;

  /// Destination token address
  final String toToken;

  /// Protocol used for this step
  final String protocol;

  /// Pool address (if applicable)
  final String? poolAddress;

  /// Pool fee (if applicable, in basis points)
  final int? poolFee;

  /// Expected output amount
  final Decimal expectedOutput;

  const SwapStep({
    required this.fromToken,
    required this.toToken,
    required this.protocol,
    this.poolAddress,
    this.poolFee,
    required this.expectedOutput,
  });

  @override
  List<Object?> get props => [
        fromToken,
        toToken,
        protocol,
        poolAddress,
        poolFee,
        expectedOutput,
      ];
}
