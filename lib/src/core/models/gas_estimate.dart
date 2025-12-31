import 'package:decimal/decimal.dart';
import 'package:equatable/equatable.dart';

/// Gas estimation for a swap transaction
class GasEstimate extends Equatable {
  /// Estimated gas limit
  final BigInt gasLimit;

  /// Current gas price (in wei)
  final BigInt gasPrice;

  /// Max fee per gas (EIP-1559)
  final BigInt? maxFeePerGas;

  /// Max priority fee per gas (EIP-1559)
  final BigInt? maxPriorityFeePerGas;

  /// Estimated cost in native token (e.g., ETH)
  final Decimal estimatedCost;

  /// Estimated cost in the output token (if available)
  final Decimal estimatedCostInToken;

  /// Native token symbol for the chain
  final String nativeSymbol;

  /// Whether EIP-1559 is supported
  bool get supportsEip1559 =>
      maxFeePerGas != null && maxPriorityFeePerGas != null;

  /// Get total gas cost in wei
  BigInt get totalGasCost {
    if (supportsEip1559) {
      return gasLimit * maxFeePerGas!;
    }
    return gasLimit * gasPrice;
  }

  GasEstimate({
    required this.gasLimit,
    required this.gasPrice,
    this.maxFeePerGas,
    this.maxPriorityFeePerGas,
    required this.estimatedCost,
    Decimal? estimatedCostInToken,
    required this.nativeSymbol,
  }) : estimatedCostInToken = estimatedCostInToken ?? Decimal.zero;

  /// Create a zero gas estimate
  factory GasEstimate.zero({String nativeSymbol = 'ETH'}) {
    return GasEstimate(
      gasLimit: BigInt.zero,
      gasPrice: BigInt.zero,
      estimatedCost: Decimal.zero,
      nativeSymbol: nativeSymbol,
    );
  }

  /// Create from wei values
  factory GasEstimate.fromWei({
    required BigInt gasLimit,
    required BigInt gasPrice,
    BigInt? maxFeePerGas,
    BigInt? maxPriorityFeePerGas,
    required String nativeSymbol,
    Decimal? tokenPrice,
  }) {
    final effectiveGasPrice = maxFeePerGas ?? gasPrice;
    final totalWei = gasLimit * effectiveGasPrice;

    // Convert wei to ETH (18 decimals)
    final divisor = BigInt.from(10).pow(18);
    final ethCost = (Decimal.fromBigInt(totalWei) / Decimal.fromBigInt(divisor))
        .toDecimal();

    // Calculate cost in token if price is provided
    final tokenCost = tokenPrice != null && tokenPrice > Decimal.zero
        ? ethCost * tokenPrice
        : Decimal.zero;

    return GasEstimate(
      gasLimit: gasLimit,
      gasPrice: gasPrice,
      maxFeePerGas: maxFeePerGas,
      maxPriorityFeePerGas: maxPriorityFeePerGas,
      estimatedCost: ethCost,
      estimatedCostInToken: tokenCost,
      nativeSymbol: nativeSymbol,
    );
  }

  @override
  List<Object?> get props => [
        gasLimit,
        gasPrice,
        maxFeePerGas,
        maxPriorityFeePerGas,
        estimatedCost,
        nativeSymbol,
      ];

  @override
  String toString() =>
      'GasEstimate(limit: $gasLimit, cost: $estimatedCost $nativeSymbol)';
}
