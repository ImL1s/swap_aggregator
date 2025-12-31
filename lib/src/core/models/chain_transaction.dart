import 'package:equatable/equatable.dart';
import 'package:decimal/decimal.dart';

import 'chain_id.dart';

/// Human-readable summary of a transaction for hardware wallet display
class TransactionSummary extends Equatable {
  /// Action type (Swap, Approve, Bridge, Send)
  final String action;

  /// Source asset symbol
  final String fromAsset;

  /// Destination asset symbol
  final String toAsset;

  /// Input amount in human-readable format
  final Decimal inputAmount;

  /// Expected output amount
  final Decimal expectedOutput;

  /// Destination chain (for cross-chain operations)
  final String? destinationChain;

  /// Protocol/DEX name
  final String protocol;

  const TransactionSummary({
    required this.action,
    required this.fromAsset,
    required this.toAsset,
    required this.inputAmount,
    required this.expectedOutput,
    this.destinationChain,
    required this.protocol,
  });

  @override
  List<Object?> get props => [
        action,
        fromAsset,
        toAsset,
        inputAmount,
        expectedOutput,
        destinationChain,
        protocol,
      ];

  @override
  String toString() =>
      '$action: $inputAmount $fromAsset → $expectedOutput $toAsset via $protocol';
}

/// Base sealed class for multi-chain transaction support
///
/// Use pattern matching to handle different chain types:
/// ```dart
/// switch (transaction) {
///   case EvmTransaction tx:
///     // Handle EVM transaction
///   case SolanaTransaction tx:
///     // Handle Solana transaction
///   case UtxoTransaction tx:
///     // Handle UTXO transaction
///   case CosmosTransaction tx:
///     // Handle Cosmos transaction
/// }
/// ```
sealed class ChainTransaction extends Equatable {
  /// Chain identifier
  ChainId get chainId;

  /// Provider-specific metadata
  Map<String, dynamic> get metadata;

  /// Human-readable transaction summary
  TransactionSummary get summary;

  const ChainTransaction();
}

/// EVM-compatible transaction (Ethereum, BSC, Polygon, Arbitrum, etc.)
class EvmTransaction extends ChainTransaction {
  /// Sender address
  final String from;

  /// Contract/router address
  final String to;

  /// Transaction calldata
  final String data;

  /// Value in wei (for native token transfers)
  final BigInt value;

  /// Gas limit
  final BigInt gasLimit;

  /// Legacy gas price
  final BigInt gasPrice;

  /// Max fee per gas (EIP-1559)
  final BigInt? maxFeePerGas;

  /// Max priority fee per gas (EIP-1559)
  final BigInt? maxPriorityFeePerGas;

  /// Transaction nonce
  final int? nonce;

  @override
  final ChainId chainId;

  @override
  final Map<String, dynamic> metadata;

  @override
  final TransactionSummary summary;

  /// Whether this uses EIP-1559 gas pricing
  bool get isEip1559 => maxFeePerGas != null && maxPriorityFeePerGas != null;

  const EvmTransaction({
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
    required this.summary,
  });

  /// Convert to JSON for signing
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

  @override
  List<Object?> get props => [from, to, data, value, gasLimit, chainId];
}

/// Solana transaction
class SolanaTransaction extends ChainTransaction {
  /// Base64 encoded serialized transaction
  final String base64EncodedTransaction;

  /// List of required signer public keys
  final List<String> requiredSigners;

  /// Recent blockhash (optional, can be fetched before signing)
  final String? recentBlockhash;

  /// Compute unit limit
  final int? computeUnitLimit;

  /// Compute unit price (for priority fees)
  final int? computeUnitPrice;

  @override
  final ChainId chainId;

  @override
  final Map<String, dynamic> metadata;

  @override
  final TransactionSummary summary;

  const SolanaTransaction({
    required this.base64EncodedTransaction,
    this.requiredSigners = const [],
    this.recentBlockhash,
    this.computeUnitLimit,
    this.computeUnitPrice,
    required this.chainId,
    this.metadata = const {},
    required this.summary,
  });

  @override
  List<Object?> get props =>
      [base64EncodedTransaction, requiredSigners, chainId];
}

/// UTXO input for Bitcoin-like chains
class UtxoInput extends Equatable {
  /// Previous transaction hash
  final String txHash;

  /// Output index in previous transaction
  final int vout;

  /// Script public key
  final String? scriptPubKey;

  /// Input value in satoshis
  final BigInt value;

  /// Derivation path (for HD wallets)
  final String? derivationPath;

  const UtxoInput({
    required this.txHash,
    required this.vout,
    this.scriptPubKey,
    required this.value,
    this.derivationPath,
  });

  @override
  List<Object?> get props => [txHash, vout, value];
}

/// UTXO output for Bitcoin-like chains
class UtxoOutput extends Equatable {
  /// Recipient address
  final String address;

  /// Output value in satoshis
  final BigInt value;

  /// Is this a change output?
  final bool isChange;

  const UtxoOutput({
    required this.address,
    required this.value,
    this.isChange = false,
  });

  @override
  List<Object?> get props => [address, value, isChange];
}

/// UTXO transaction for Bitcoin, Litecoin, Dogecoin, etc.
class UtxoTransaction extends ChainTransaction {
  /// Transaction inputs
  final List<UtxoInput> inputs;

  /// Transaction outputs
  final List<UtxoOutput> outputs;

  /// Fee rate in satoshis per virtual byte
  final int feeRateSatPerVb;

  /// Total fee in satoshis
  BigInt get totalFee {
    final inputSum = inputs.fold<BigInt>(BigInt.zero, (a, b) => a + b.value);
    final outputSum = outputs.fold<BigInt>(BigInt.zero, (a, b) => a + b.value);
    return inputSum - outputSum;
  }

  @override
  final ChainId chainId;

  @override
  final Map<String, dynamic> metadata;

  @override
  final TransactionSummary summary;

  const UtxoTransaction({
    required this.inputs,
    required this.outputs,
    required this.feeRateSatPerVb,
    required this.chainId,
    this.metadata = const {},
    required this.summary,
  });

  @override
  List<Object?> get props => [inputs, outputs, feeRateSatPerVb, chainId];
}

/// Cosmos message for IBC transactions
class CosmosMessage extends Equatable {
  /// Message type URL (e.g., "/cosmos.bank.v1beta1.MsgSend")
  final String typeUrl;

  /// Message value as JSON
  final Map<String, dynamic> value;

  const CosmosMessage({
    required this.typeUrl,
    required this.value,
  });

  @override
  List<Object?> get props => [typeUrl, value];
}

/// Cosmos fee structure
class CosmosFee extends Equatable {
  /// Fee amount
  final List<CosmosCoin> amount;

  /// Gas limit
  final BigInt gasLimit;

  /// Granter address (for fee grants)
  final String? granter;

  /// Payer address
  final String? payer;

  const CosmosFee({
    required this.amount,
    required this.gasLimit,
    this.granter,
    this.payer,
  });

  @override
  List<Object?> get props => [amount, gasLimit, granter, payer];
}

/// Cosmos coin denomination
class CosmosCoin extends Equatable {
  final String denom;
  final BigInt amount;

  const CosmosCoin({required this.denom, required this.amount});

  @override
  List<Object?> get props => [denom, amount];
}

/// Cosmos transaction for Cosmos SDK chains (Cosmos Hub, Osmosis, etc.)
class CosmosTransaction extends ChainTransaction {
  /// Transaction messages
  final List<CosmosMessage> messages;

  /// Transaction fee
  final CosmosFee fee;

  /// Transaction memo
  final String memo;

  /// Account number
  final int? accountNumber;

  /// Sequence number
  final int? sequence;

  @override
  final ChainId chainId;

  @override
  final Map<String, dynamic> metadata;

  @override
  final TransactionSummary summary;

  const CosmosTransaction({
    required this.messages,
    required this.fee,
    this.memo = '',
    this.accountNumber,
    this.sequence,
    required this.chainId,
    this.metadata = const {},
    required this.summary,
  });

  @override
  List<Object?> get props =>
      [messages, fee, memo, accountNumber, sequence, chainId];
}
