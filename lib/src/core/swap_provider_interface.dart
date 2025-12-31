import 'package:decimal/decimal.dart';

import '../utils/result.dart';
import 'models/approval_method.dart';
import 'models/chain_id.dart';
import 'models/chain_transaction.dart';
import 'models/swap_params.dart';
import 'models/swap_quote.dart';
import 'models/swap_transaction.dart';
import 'models/swap_status.dart';
import 'models/token.dart';

/// Interface for all swap providers
///
/// Implement this interface to add support for a new DEX aggregator.
/// Each provider handles quote retrieval, transaction building, and
/// approval management for a specific aggregator API.
///
/// ## Example Implementation
///
/// ```dart
/// class MyCustomProvider implements SwapProviderInterface {
///   @override
///   String get name => 'MyCustomDEX';
///
///   @override
///   List<ChainId> get supportedChains => [ChainId.ethereum, ChainId.bsc];
///
///   @override
///   bool get supportsCrossChain => false;
///
///   // ... implement other methods
/// }
/// ```
abstract class SwapProviderInterface {
  /// Unique provider name (e.g., '1inch', 'ParaSwap', 'Uniswap')
  String get name;

  /// List of supported chains
  List<ChainId> get supportedChains;

  /// Whether this provider supports cross-chain swaps
  bool get supportsCrossChain;

  /// Check if a specific chain is supported
  bool isChainSupported(ChainId chainId) => supportedChains.contains(chainId);

  /// Check if cross-chain swap is supported between two chains
  bool isCrossChainSupported(ChainId fromChain, ChainId toChain) {
    if (!supportsCrossChain) return false;
    return isChainSupported(fromChain) && isChainSupported(toChain);
  }

  /// Get available tokens for a chain
  ///
  /// Returns a list of tokens that can be swapped on the specified chain.
  Future<Result<List<Token>>> getTokens(ChainId chainId);

  /// Get a swap quote
  ///
  /// Returns pricing and routing information for the specified swap parameters.
  Future<Result<SwapQuote>> getQuote(SwapParams params);

  /// Build a swap transaction (V1 - EVM only)
  ///
  /// Converts a quote into a transaction ready for signing.
  ///
  /// @deprecated Use [buildTransactionV2] for multi-chain support.
  Future<Result<SwapTransaction>> buildTransaction({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  });

  /// Build a swap transaction (V2 - Multi-chain)
  ///
  /// Returns a chain-specific transaction type using sealed classes.
  /// Use pattern matching to handle different chain types:
  /// ```dart
  /// final result = await provider.buildTransactionV2(...);
  /// result.when(
  ///   success: (tx) {
  ///     switch (tx) {
  ///       case EvmTransaction evmTx:
  ///         // Sign with EVM wallet
  ///       case SolanaTransaction solanaTx:
  ///         // Sign with Solana wallet
  ///       case UtxoTransaction utxoTx:
  ///         // Sign with Bitcoin wallet
  ///       case CosmosTransaction cosmosTx:
  ///         // Sign with Cosmos wallet
  ///     }
  ///   },
  ///   failure: (error) => handleError(error),
  /// );
  /// ```
  Future<Result<ChainTransaction>> buildTransactionV2({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    // Default implementation: wrap legacy buildTransaction result
    final legacyResult = await buildTransaction(
      quote: quote,
      userAddress: userAddress,
      recipientAddress: recipientAddress,
    );

    if (legacyResult.isFailure) {
      return Result.failure(legacyResult.errorOrNull!);
    }

    final legacy = legacyResult.valueOrNull!;
    return Result.success(EvmTransaction(
      from: legacy.from,
      to: legacy.to,
      data: legacy.data,
      value: legacy.value,
      gasLimit: legacy.gasLimit,
      gasPrice: legacy.gasPrice,
      maxFeePerGas: legacy.maxFeePerGas,
      maxPriorityFeePerGas: legacy.maxPriorityFeePerGas,
      nonce: legacy.nonce,
      chainId: legacy.chainId,
      metadata: legacy.metadata,
      summary: TransactionSummary(
        action: 'Swap',
        fromAsset: quote.params.fromToken,
        toAsset: quote.params.toToken,
        inputAmount: quote.inputAmount,
        expectedOutput: quote.outputAmount,
        destinationChain:
            quote.params.isCrossChain ? quote.params.toChain.name : null,
        protocol: name,
      ),
    ));
  }

  /// Check token allowance
  ///
  /// Returns the current approved amount for the router contract.
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  });

  /// Get approval transaction data (V1)
  ///
  /// Returns the transaction data needed to approve token spending.
  ///
  /// @deprecated Use [getApprovalMethod] for Permit2/EIP-712 support.
  Future<Result<ApprovalTransaction>> getApprovalTransaction({
    required ChainId chainId,
    required String tokenAddress,
    BigInt? amount, // null = unlimited approval
  });

  /// Get the appropriate approval method (V2)
  ///
  /// Returns the best approval strategy for the token/provider combination.
  /// Supports Standard ERC20, Permit (EIP-2612), and Permit2.
  Future<Result<ApprovalMethod>> getApprovalMethod({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
    required BigInt amount,
  }) async {
    // Default: fall back to standard approval
    final spenderResult = await getSpenderAddress(chainId);
    if (spenderResult.isFailure) {
      // Check if it's a non-EVM chain that doesn't need approvals
      if (chainId == ChainId.solana || chainId == ChainId.bitcoin) {
        return Result.success(NoApprovalNeeded(
            reason: '${chainId.name} does not use ERC20 approvals'));
      }
      return Result.failure(spenderResult.errorOrNull!);
    }

    final allowanceResult = await checkAllowance(
      chainId: chainId,
      tokenAddress: tokenAddress,
      ownerAddress: ownerAddress,
    );

    if (allowanceResult.isSuccess && allowanceResult.valueOrNull! >= amount) {
      return Result.success(
          NoApprovalNeeded(reason: 'Sufficient allowance already granted'));
    }

    final approvalResult = await getApprovalTransaction(
      chainId: chainId,
      tokenAddress: tokenAddress,
      amount: amount,
    );

    if (approvalResult.isFailure) {
      return Result.failure(approvalResult.errorOrNull!);
    }

    final approval = approvalResult.valueOrNull!;
    final tx = approval.transaction;

    if (tx == null) {
      return Result.failure('Approval transaction data not available');
    }

    return Result.success(StandardApproval(
      transaction: EvmTransaction(
        from: ownerAddress,
        to: tx.to,
        data: tx.data,
        value: tx.value,
        gasLimit: tx.gasLimit,
        gasPrice: tx.gasPrice,
        chainId: chainId,
        summary: TransactionSummary(
          action: 'Approve',
          fromAsset: tokenAddress,
          toAsset: tokenAddress,
          inputAmount: Decimal.zero,
          expectedOutput: Decimal.zero,
          protocol: name,
        ),
      ),
      tokenAddress: tokenAddress,
      spenderAddress: approval.spenderAddress,
      amount: amount,
    ));
  }

  /// Get transaction status
  ///
  /// Checks the status of a specific swap transaction.
  /// Primarily used for cross-chain swaps (e.g., Rango).
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  });

  /// Get the router/spender address for approvals
  Future<Result<String>> getSpenderAddress(ChainId chainId);

  /// Dispose resources
  void dispose() {}
}
