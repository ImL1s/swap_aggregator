import 'dart:async';

import 'package:collection/collection.dart';

import '../core/models/chain_id.dart';
import '../core/models/swap_params.dart';
import '../core/models/swap_quote.dart';
import '../core/models/swap_status.dart';
import '../core/models/swap_transaction.dart';
import '../core/models/token.dart';
import '../core/swap_aggregator_interface.dart';
import '../core/swap_provider_interface.dart';
import '../utils/result.dart';
import 'quote_comparator.dart';

/// Main implementation of the Swap Aggregator Service
class SwapAggregatorService implements SwapAggregatorInterface {
  final List<SwapProviderInterface> _providers;

  SwapAggregatorService({List<SwapProviderInterface>? providers})
      : _providers = providers ?? [];

  @override
  List<SwapProviderInterface> get providers => List.unmodifiable(_providers);

  @override
  void registerProvider(SwapProviderInterface provider) {
    if (!_providers.any((p) => p.name == provider.name)) {
      _providers.add(provider);
    }
  }

  @override
  void unregisterProvider(String name) {
    _providers.removeWhere((p) => p.name == name);
  }

  @override
  SwapProviderInterface? getProvider(String name) {
    return _providers.firstWhereOrNull((p) => p.name == name);
  }

  @override
  List<SwapProviderInterface> getProvidersForChain(ChainId chainId) {
    return _providers.where((p) => p.isChainSupported(chainId)).toList();
  }

  @override
  List<SwapProviderInterface> getCrossChainProviders() {
    return _providers.where((p) => p.supportsCrossChain).toList();
  }

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      final providers = getProvidersForChain(chainId);
      if (providers.isEmpty) return Result.success([]);

      // Fetch from all providers in parallel
      final results = await Future.wait(
        providers.map((p) => p.getTokens(chainId)),
      );

      // Aggregate and deduplicate tokens
      final uniqueTokens = <String, Token>{};
      for (final result in results) {
        if (result.isSuccess) {
          for (final token in result.valueOrNull!) {
            final key = token.address.toLowerCase();
            if (!uniqueTokens.containsKey(key)) {
              uniqueTokens[key] = token;
            }
          }
        }
      }

      return Result.success(uniqueTokens.values.toList());
    } catch (e) {
      return Result.failure('Failed to aggregate tokens: $e');
    }
  }

  @override
  Future<List<SwapQuote>> getQuotes(SwapParams params) async {
    final eligibleProviders = params.isCrossChain
        ? _providers.where(
            (p) => p.isCrossChainSupported(params.fromChain, params.toChain),
          )
        : _providers.where((p) => p.isChainSupported(params.fromChain));

    if (eligibleProviders.isEmpty) return [];

    // Fetch quotes in parallel
    final quoteFutures = eligibleProviders.map((provider) async {
      try {
        final result = await provider.getQuote(params);
        return result.valueOrNull;
      } catch (e) {
        // Log error but don't fail other providers
        print('Provider ${provider.name} failed: $e');
        return null;
      }
    });

    final results = await Future.wait(quoteFutures);
    final quotes = results.whereType<SwapQuote>().toList();

    // Sort and return
    return QuoteComparator.sortQuotes(quotes);
  }

  @override
  Future<Result<SwapQuote>> getBestQuote(SwapParams params) async {
    final quotes = await getQuotes(params);
    if (quotes.isEmpty) {
      return Result.failure('No quotes available');
    }
    return Result.success(quotes.first);
  }

  @override
  Future<Result<SwapTransaction>> buildTransaction({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    final provider = getProvider(quote.provider);
    if (provider == null) {
      return Result.failure(
        'Provider ${quote.provider} not found',
        code: 'PROVIDER_NOT_FOUND',
      );
    }

    return provider.buildTransaction(
      quote: quote,
      userAddress: userAddress,
      recipientAddress: recipientAddress,
    );
  }

  @override
  Future<Result<bool>> needsApproval({
    required SwapParams params,
    required String providerName,
  }) async {
    final provider = getProvider(providerName);
    if (provider == null) {
      return Result.failure('Provider not found');
    }

    // Native tokens don't need approval
    if (params.fromTokenAddress.toLowerCase() ==
            params.fromChain.nativeTokenAddress.toLowerCase() ||
        params.fromTokenAddress ==
            '0x0000000000000000000000000000000000000000' ||
        params.fromTokenAddress.isEmpty ||
        params.fromTokenAddress.toLowerCase() == 'native') {
      return Result.success(false);
    }

    final allowanceResult = await provider.checkAllowance(
      chainId: params.fromChain,
      tokenAddress: params.fromTokenAddress,
      ownerAddress: params.userAddress,
    );

    if (allowanceResult.isFailure) {
      return Result.failure(allowanceResult.errorOrNull!);
    }

    final allowance = allowanceResult.valueOrNull!;
    return Result.success(allowance < params.amountInSmallestUnit);
  }

  @override
  Future<Result<ApprovalTransaction?>> getApprovalIfNeeded({
    required SwapParams params,
    required String providerName,
    BigInt? amount,
  }) async {
    final neededResult = await needsApproval(
      params: params,
      providerName: providerName,
    );

    if (neededResult.isFailure) {
      return Result.failure(neededResult.errorOrNull!);
    }

    if (!neededResult.valueOrNull!) {
      return Result.success(null);
    }

    final provider = getProvider(providerName)!;
    final approvalResult = await provider.getApprovalTransaction(
      chainId: params.fromChain,
      tokenAddress: params.fromTokenAddress,
      amount: amount,
    );

    if (approvalResult.isFailure) {
      return Result.failure(approvalResult.errorOrNull!);
    }

    return Result.success(approvalResult.valueOrNull);
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
    String? providerName,
  }) async {
    // This would typically involve querying the blockchain provider
    // or the specific swap provider's status API (e.g., Rango).
    // For now, we return a pending status.
    return Result.success(SwapStatus.pending(txHash));
  }

  @override
  void dispose() {
    for (final provider in _providers) {
      provider.dispose();
    }
  }
}
