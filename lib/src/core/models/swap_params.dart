import 'package:decimal/decimal.dart';
import 'package:equatable/equatable.dart';

import 'chain_id.dart';

/// Parameters for a swap request
///
/// This class encapsulates all the information needed to request
/// a quote from a swap provider.
class SwapParams extends Equatable {
  /// Source chain
  final ChainId fromChain;

  /// Destination chain (same as fromChain for same-chain swaps)
  final ChainId toChain;

  /// Source token symbol (e.g., 'ETH', 'USDC')
  final String fromToken;

  /// Destination token symbol
  final String toToken;

  /// Source token contract address
  final String fromTokenAddress;

  /// Destination token contract address
  final String toTokenAddress;

  /// Amount to swap (in human-readable units, not wei)
  final Decimal amount;

  /// Source token decimals
  final int fromTokenDecimals;

  /// Destination token decimals
  final int toTokenDecimals;

  /// User's wallet address
  final String userAddress;

  /// Recipient address (defaults to userAddress if null)
  final String? recipientAddress;

  /// Slippage tolerance in percentage (e.g., 1.0 = 1%)
  final double slippage;

  /// Whether this is a cross-chain swap
  bool get isCrossChain => fromChain != toChain;

  /// Get the effective recipient address
  String get effectiveRecipient => recipientAddress ?? userAddress;

  /// Get amount in smallest unit (wei for ETH, etc.)
  BigInt get amountInSmallestUnit {
    final multiplier = BigInt.from(10).pow(fromTokenDecimals);
    return (amount * Decimal.fromBigInt(multiplier)).toBigInt();
  }

  const SwapParams({
    required this.fromChain,
    required this.toChain,
    required this.fromToken,
    required this.toToken,
    required this.fromTokenAddress,
    required this.toTokenAddress,
    required this.amount,
    required this.userAddress,
    this.fromTokenDecimals = 18,
    this.toTokenDecimals = 18,
    this.recipientAddress,
    this.slippage = 1.0,
  });

  /// Create a copy with modified fields
  SwapParams copyWith({
    ChainId? fromChain,
    ChainId? toChain,
    String? fromToken,
    String? toToken,
    String? fromTokenAddress,
    String? toTokenAddress,
    Decimal? amount,
    String? userAddress,
    int? fromTokenDecimals,
    int? toTokenDecimals,
    String? recipientAddress,
    double? slippage,
  }) {
    return SwapParams(
      fromChain: fromChain ?? this.fromChain,
      toChain: toChain ?? this.toChain,
      fromToken: fromToken ?? this.fromToken,
      toToken: toToken ?? this.toToken,
      fromTokenAddress: fromTokenAddress ?? this.fromTokenAddress,
      toTokenAddress: toTokenAddress ?? this.toTokenAddress,
      amount: amount ?? this.amount,
      userAddress: userAddress ?? this.userAddress,
      fromTokenDecimals: fromTokenDecimals ?? this.fromTokenDecimals,
      toTokenDecimals: toTokenDecimals ?? this.toTokenDecimals,
      recipientAddress: recipientAddress ?? this.recipientAddress,
      slippage: slippage ?? this.slippage,
    );
  }

  @override
  List<Object?> get props => [
    fromChain,
    toChain,
    fromToken,
    toToken,
    fromTokenAddress,
    toTokenAddress,
    amount,
    userAddress,
    fromTokenDecimals,
    toTokenDecimals,
    recipientAddress,
    slippage,
  ];

  @override
  String toString() =>
      'SwapParams($fromToken → $toToken, amount: $amount, chain: ${fromChain.name})';
}
