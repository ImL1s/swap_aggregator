import 'package:equatable/equatable.dart';

import 'chain_id.dart';
import 'chain_transaction.dart';

/// EIP-712 typed data for Permit/Permit2 signatures
class Eip712TypedData extends Equatable {
  /// Domain separator
  final Eip712Domain domain;

  /// Message types definition
  final Map<String, List<Eip712Type>> types;

  /// Primary type name
  final String primaryType;

  /// Message data
  final Map<String, dynamic> message;

  const Eip712TypedData({
    required this.domain,
    required this.types,
    required this.primaryType,
    required this.message,
  });

  /// Convert to JSON for wallet signing
  Map<String, dynamic> toJson() => {
        'types':
            types.map((k, v) => MapEntry(k, v.map((t) => t.toJson()).toList())),
        'primaryType': primaryType,
        'domain': domain.toJson(),
        'message': message,
      };

  @override
  List<Object?> get props => [domain, types, primaryType, message];
}

/// EIP-712 domain separator
class Eip712Domain extends Equatable {
  final String name;
  final String version;
  final int chainId;
  final String verifyingContract;
  final String? salt;

  const Eip712Domain({
    required this.name,
    required this.version,
    required this.chainId,
    required this.verifyingContract,
    this.salt,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'version': version,
        'chainId': chainId,
        'verifyingContract': verifyingContract,
        if (salt != null) 'salt': salt,
      };

  @override
  List<Object?> get props => [name, version, chainId, verifyingContract, salt];
}

/// EIP-712 type definition
class Eip712Type extends Equatable {
  final String name;
  final String type;

  const Eip712Type({required this.name, required this.type});

  Map<String, String> toJson() => {'name': name, 'type': type};

  @override
  List<Object?> get props => [name, type];
}

/// Sealed class for different approval methods
///
/// Use pattern matching to handle different approval types:
/// ```dart
/// switch (approval) {
///   case StandardApproval a:
///     // Submit ERC20 approve transaction
///   case PermitSignature p:
///     // Request EIP-712 signature
///   case Permit2Signature p2:
///     // Request Permit2 signature
///   case NoApprovalNeeded _:
///     // Proceed directly to swap
/// }
/// ```
sealed class ApprovalMethod extends Equatable {
  const ApprovalMethod();
}

/// Standard ERC20 approve transaction
class StandardApproval extends ApprovalMethod {
  /// The approval transaction to be signed and submitted
  final EvmTransaction transaction;

  /// Token address being approved
  final String tokenAddress;

  /// Spender (router) address
  final String spenderAddress;

  /// Approval amount (max uint256 for unlimited)
  final BigInt amount;

  const StandardApproval({
    required this.transaction,
    required this.tokenAddress,
    required this.spenderAddress,
    required this.amount,
  });

  /// Is this an unlimited approval?
  bool get isUnlimited =>
      amount ==
      BigInt.parse(
        'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        radix: 16,
      );

  @override
  List<Object?> get props => [tokenAddress, spenderAddress, amount];
}

/// EIP-2612 Permit (gasless approval via signature)
class PermitSignature extends ApprovalMethod {
  /// EIP-712 typed data to sign
  final Eip712TypedData typedData;

  /// Token address
  final String tokenAddress;

  /// Spender address
  final String spenderAddress;

  /// Approval amount
  final BigInt amount;

  /// Signature validity duration
  final Duration validity;

  /// Deadline timestamp
  final int deadline;

  /// Nonce for replay protection
  final int nonce;

  const PermitSignature({
    required this.typedData,
    required this.tokenAddress,
    required this.spenderAddress,
    required this.amount,
    required this.validity,
    required this.deadline,
    required this.nonce,
  });

  @override
  List<Object?> get props =>
      [tokenAddress, spenderAddress, amount, deadline, nonce];
}

/// Permit2 signature (Uniswap standard for batch approvals)
class Permit2Signature extends ApprovalMethod {
  /// EIP-712 typed data to sign
  final Eip712TypedData typedData;

  /// Permit2 contract address
  final String permit2ContractAddress;

  /// Token address
  final String tokenAddress;

  /// Spender address
  final String spenderAddress;

  /// Approval amount
  final BigInt amount;

  /// Nonce for replay protection
  final BigInt nonce;

  /// Signature deadline
  final int deadline;

  /// Chain ID
  final ChainId chainId;

  const Permit2Signature({
    required this.typedData,
    required this.permit2ContractAddress,
    required this.tokenAddress,
    required this.spenderAddress,
    required this.amount,
    required this.nonce,
    required this.deadline,
    required this.chainId,
  });

  @override
  List<Object?> get props =>
      [permit2ContractAddress, tokenAddress, spenderAddress, amount, nonce];
}

/// No approval needed (native tokens, pre-approved, or non-EVM chains)
class NoApprovalNeeded extends ApprovalMethod {
  /// Reason why no approval is needed
  final String reason;

  const NoApprovalNeeded({required this.reason});

  @override
  List<Object?> get props => [reason];
}
