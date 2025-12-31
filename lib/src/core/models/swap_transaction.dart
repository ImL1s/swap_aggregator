import 'package:equatable/equatable.dart';

import 'chain_id.dart';

/// Represents a swap transaction ready for signing
class SwapTransaction extends Equatable {
  /// Sender address
  final String from;

  /// Contract/router address
  final String to;

  /// Transaction data (calldata)
  final String data;

  /// Value in wei (for native token swaps)
  final BigInt value;

  /// Gas limit
  final BigInt gasLimit;

  /// Gas price (legacy)
  final BigInt gasPrice;

  /// Max fee per gas (EIP-1559)
  final BigInt? maxFeePerGas;

  /// Max priority fee per gas (EIP-1559)
  final BigInt? maxPriorityFeePerGas;

  /// Transaction nonce (optional, can be fetched)
  final int? nonce;

  /// Chain identifier
  final ChainId chainId;

  /// Additional metadata from provider
  final Map<String, dynamic> metadata;

  /// Whether this uses EIP-1559 gas pricing
  bool get isEip1559 => maxFeePerGas != null && maxPriorityFeePerGas != null;

  const SwapTransaction({
    required this.from,
    required this.to,
    required this.data,
    required this.value,
    required this.gasLimit,
    required this.gasPrice,
    this.maxFeePerGas,
    this.maxPriorityFeePerGas,
    this.nonce,
    required this.chainId,
    this.metadata = const {},
  });

  /// Convert to a map for JSON serialization
  Map<String, dynamic> toJson() {
    return {
      'from': from,
      'to': to,
      'data': data,
      'value': '0x${value.toRadixString(16)}',
      'gas': '0x${gasLimit.toRadixString(16)}',
      'gasPrice': '0x${gasPrice.toRadixString(16)}',
      if (maxFeePerGas != null)
        'maxFeePerGas': '0x${maxFeePerGas!.toRadixString(16)}',
      if (maxPriorityFeePerGas != null)
        'maxPriorityFeePerGas': '0x${maxPriorityFeePerGas!.toRadixString(16)}',
      if (nonce != null) 'nonce': '0x${nonce!.toRadixString(16)}',
      'chainId': '0x${chainId.id.toRadixString(16)}',
    };
  }

  /// Create from provider response
  factory SwapTransaction.fromJson(Map<String, dynamic> json, ChainId chainId) {
    BigInt parseHexOrInt(dynamic value) {
      if (value == null) return BigInt.zero;
      if (value is int) return BigInt.from(value);
      if (value is String) {
        if (value.startsWith('0x')) {
          return BigInt.parse(value.substring(2), radix: 16);
        }
        return BigInt.parse(value);
      }
      return BigInt.zero;
    }

    return SwapTransaction(
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      data: json['data'] as String? ?? '0x',
      value: parseHexOrInt(json['value']),
      gasLimit: parseHexOrInt(json['gas'] ?? json['gasLimit']),
      gasPrice: parseHexOrInt(json['gasPrice']),
      maxFeePerGas: json['maxFeePerGas'] != null
          ? parseHexOrInt(json['maxFeePerGas'])
          : null,
      maxPriorityFeePerGas: json['maxPriorityFeePerGas'] != null
          ? parseHexOrInt(json['maxPriorityFeePerGas'])
          : null,
      nonce: json['nonce'] != null
          ? parseHexOrInt(json['nonce']).toInt()
          : null,
      chainId: chainId,
      metadata: json,
    );
  }

  @override
  List<Object?> get props => [from, to, data, value, gasLimit, chainId];

  @override
  String toString() =>
      'SwapTransaction(to: $to, value: $value, chain: ${chainId.name})';
}

/// Approval transaction for ERC20 tokens
class ApprovalTransaction extends Equatable {
  /// Token contract address
  final String tokenAddress;

  /// Spender address (usually router)
  final String spenderAddress;

  /// Amount to approve (max uint256 for unlimited)
  final BigInt amount;

  /// Chain identifier
  final ChainId chainId;

  /// Pre-built transaction data (if available)
  final SwapTransaction? transaction;

  /// Check if this is unlimited approval
  bool get isUnlimited =>
      amount ==
      BigInt.parse(
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        radix: 16,
      );

  const ApprovalTransaction({
    required this.tokenAddress,
    required this.spenderAddress,
    required this.amount,
    required this.chainId,
    this.transaction,
  });

  /// Create unlimited approval
  factory ApprovalTransaction.unlimited({
    required String tokenAddress,
    required String spenderAddress,
    required ChainId chainId,
    SwapTransaction? transaction,
  }) {
    return ApprovalTransaction(
      tokenAddress: tokenAddress,
      spenderAddress: spenderAddress,
      amount: BigInt.parse(
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        radix: 16,
      ),
      chainId: chainId,
      transaction: transaction,
    );
  }

  @override
  List<Object?> get props => [tokenAddress, spenderAddress, amount, chainId];
}
