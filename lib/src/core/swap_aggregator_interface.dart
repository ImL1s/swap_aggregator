import '../utils/result.dart';
import 'models/chain_id.dart';
import 'models/chain_transaction.dart';
import 'models/swap_params.dart';
import 'models/swap_quote.dart';
import 'models/swap_status.dart';
import 'models/swap_transaction.dart';
import 'models/token.dart';
import 'swap_provider_interface.dart';

/// Interface for swap aggregator services
///
/// This interface defines the contract for aggregator implementations
/// that can manage multiple providers and select the best quotes.
abstract class SwapAggregatorInterface {
  /// Get all registered providers
  List<SwapProviderInterface> get providers;

  /// Register a new provider
  void registerProvider(SwapProviderInterface provider);

  /// Unregister a provider by name
  void unregisterProvider(String name);

  /// Get a provider by name
  SwapProviderInterface? getProvider(String name);

  /// Get providers that support a specific chain
  List<SwapProviderInterface> getProvidersForChain(ChainId chainId);

  /// Get providers that support cross-chain swaps
  List<SwapProviderInterface> getCrossChainProviders();

  /// Get available tokens for a chain (aggregated from all providers)
  Future<Result<List<Token>>> getTokens(ChainId chainId);

  /// Get quotes from all applicable providers
  ///
  /// Returns a list of quotes sorted by best output amount.
  Future<List<SwapQuote>> getQuotes(SwapParams params);

  /// Get the best quote across all providers
  Future<Result<SwapQuote>> getBestQuote(SwapParams params);

  /// Build a transaction for a specific quote
  Future<Result<SwapTransaction>> buildTransaction({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  });

  /// Build a transaction for a specific quote (V2 - Multi-chain)
  Future<Result<ChainTransaction>> buildTransactionV2({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  });

  /// Check if approval is needed for a swap
  Future<Result<bool>> needsApproval({
    required SwapParams params,
    required String providerName,
  });

  /// Get approval transaction if needed
  Future<Result<ApprovalTransaction?>> getApprovalIfNeeded({
    required SwapParams params,
    required String providerName,
    BigInt? amount,
  });

  /// Get swap status by transaction hash
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
    String? providerName,
  });

  /// Dispose all resources
  void dispose();
}
