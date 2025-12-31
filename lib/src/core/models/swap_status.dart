import 'package:equatable/equatable.dart';

/// Status of a swap transaction
class SwapStatus extends Equatable {
  /// Transaction hash
  final String txHash;

  /// Current status
  final SwapStatusType status;

  /// Number of confirmations
  final int confirmations;

  /// Output transaction hash (for cross-chain swaps)
  final String? outputTxHash;

  /// Actual output amount received
  final String? actualOutputAmount;

  /// Error message if failed
  final String? error;

  /// Additional metadata
  final Map<String, dynamic> metadata;

  /// Check if swap is complete
  bool get isComplete =>
      status == SwapStatusType.completed || status == SwapStatusType.failed;

  /// Check if swap is pending
  bool get isPending =>
      status == SwapStatusType.pending || status == SwapStatusType.confirming;

  const SwapStatus({
    required this.txHash,
    required this.status,
    this.confirmations = 0,
    this.outputTxHash,
    this.actualOutputAmount,
    this.error,
    this.metadata = const {},
  });

  /// Create pending status
  factory SwapStatus.pending(String txHash) {
    return SwapStatus(txHash: txHash, status: SwapStatusType.pending);
  }

  /// Create completed status
  factory SwapStatus.completed(
    String txHash, {
    String? actualOutputAmount,
    int confirmations = 1,
  }) {
    return SwapStatus(
      txHash: txHash,
      status: SwapStatusType.completed,
      confirmations: confirmations,
      actualOutputAmount: actualOutputAmount,
    );
  }

  /// Create failed status
  factory SwapStatus.failed(String txHash, String error) {
    return SwapStatus(
      txHash: txHash,
      status: SwapStatusType.failed,
      error: error,
    );
  }

  @override
  List<Object?> get props => [
        txHash,
        status,
        confirmations,
        outputTxHash,
        actualOutputAmount,
        error,
      ];

  @override
  String toString() => 'SwapStatus($txHash: ${status.name})';
}

/// Status types for swap transactions
enum SwapStatusType {
  /// Transaction submitted but not confirmed
  pending,

  /// Transaction is being confirmed
  confirming,

  /// Transaction confirmed on source chain
  confirmed,

  /// Swap completed successfully
  completed,

  /// Swap is currently processing (e.g. aggregator internal state)
  processing,

  /// Swap failed
  failed,

  /// Quote/transaction expired
  expired,

  /// Swap was cancelled
  cancelled,

  /// Waiting for bridge (cross-chain only)
  bridging,

  /// Refunding (cross-chain failure)
  refunding,
}
