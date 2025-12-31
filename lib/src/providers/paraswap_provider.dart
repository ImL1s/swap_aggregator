import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../core/models/approval_method.dart';
import '../core/models/chain_id.dart';
import '../core/models/chain_transaction.dart';
import '../core/models/gas_estimate.dart';
import '../core/models/swap_params.dart';
import '../core/models/swap_quote.dart';
import '../core/models/swap_status.dart';
import '../core/models/swap_transaction.dart';
import '../core/models/token.dart';
import '../core/swap_provider_interface.dart';
import '../utils/result.dart';

/// ParaSwap API v5 Provider
///
/// ParaSwap offers free public API access without requiring an API key.
/// API keys are optional and only needed for enterprise/dedicated access.
///
/// ## Example
/// ```dart
/// final paraswap = ParaSwapProvider();
/// final quote = await paraswap.getQuote(params);
/// ```
class ParaSwapProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://apiv5.paraswap.io';

  final Dio _dio;
  final String? _apiKey;

  /// Create a ParaSwap provider
  ///
  /// [apiKey] is optional - the public API works without authentication.
  /// [dio] can be provided for custom HTTP configuration.
  ParaSwapProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_apiKey != null) 'X-API-KEY': _apiKey,
    };
  }

  @override
  String get name => 'ParaSwap';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.polygon,
        ChainId.bsc,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.avalanche,
        ChainId.fantom,
        ChainId.base,
      ];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      final response = await _dio.get('$_baseUrl/tokens/${chainId.id}');

      final data = response.data;
      if (data['tokens'] != null) {
        final tokensMap = data['tokens'] as Map<String, dynamic>;
        final tokens = tokensMap.values
            .map((t) => Token.fromJson(t as Map<String, dynamic>, chainId))
            .toList();
        return Result.success(tokens);
      }
      return Result.success([]);
    } on DioException catch (e) {
      return Result.failure(
        'Failed to fetch tokens: ${e.message}',
        code: 'TOKENS_FETCH_ERROR',
        details: e.response?.data,
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final queryParams = {
        'srcToken': params.fromTokenAddress,
        'destToken': params.toTokenAddress,
        'amount': params.amountInSmallestUnit.toString(),
        'side': 'SELL',
        'network': params.fromChain.id.toString(),
        'userAddress': params.userAddress,
        'slippage': (params.slippage * 100).toInt().toString(),
        'srcDecimals': params.fromTokenDecimals.toString(),
        'destDecimals': params.toTokenDecimals.toString(),
      };

      final response = await _dio.get(
        '$_baseUrl/prices',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data['priceRoute'] == null) {
        return Result.failure('No route found for this swap', code: 'NO_ROUTE');
      }

      final priceRoute = data['priceRoute'];
      final quote = _parseQuote(priceRoute, params);
      return Result.success(quote);
    } on DioException catch (e) {
      return Result.failure(
        'Failed to get quote: ${e.message}',
        code: 'QUOTE_ERROR',
        details: e.response?.data,
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  @override
  Future<Result<ChainTransaction>> buildTransactionV2({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    try {
      final priceRoute = quote.metadata['priceRoute'];
      if (priceRoute == null) {
        return Result.failure(
          'Missing price route in quote metadata',
          code: 'INVALID_QUOTE',
        );
      }

      final body = {
        'srcToken': quote.params.fromTokenAddress,
        'destToken': quote.params.toTokenAddress,
        'srcAmount': priceRoute['srcAmount'],
        'destAmount': priceRoute['destAmount'],
        'priceRoute': priceRoute,
        'slippage': (quote.params.slippage * 100).toInt(),
        'userAddress': userAddress,
        'txOrigin': userAddress,
        if (recipientAddress != null) 'receiver': recipientAddress,
      };

      final response = await _dio.post(
        '$_baseUrl/transactions/${quote.params.fromChain.id}',
        data: body,
      );

      final data = response.data;

      // Add 35% safety buffer for gas
      final estimatedGas = int.parse(data['gas']?.toString() ?? '500000');
      final gasWithBuffer = (estimatedGas * 1.35).round();

      final tx = EvmTransaction(
        from: data['from'] ?? userAddress,
        to: data['to'],
        data: data['data'],
        value: BigInt.parse(data['value']?.toString() ?? '0'),
        gasLimit: BigInt.from(gasWithBuffer),
        gasPrice: BigInt.parse(data['gasPrice']?.toString() ?? '0'),
        chainId: quote.params.fromChain,
        summary: TransactionSummary(
          action: 'Swap',
          fromAsset: quote.params.fromToken,
          toAsset: quote.params.toToken,
          inputAmount: quote.inputAmount,
          expectedOutput: quote.outputAmount,
          protocol: name,
        ),
      );

      return Result.success(tx);
    } on DioException catch (e) {
      return Result.failure(
        'Failed to build transaction: ${e.message}',
        code: 'TX_BUILD_ERROR',
        details: e.response?.data,
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  @override
  @deprecated
  Future<Result<SwapTransaction>> buildTransaction({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    final result = await buildTransactionV2(
      quote: quote,
      userAddress: userAddress,
      recipientAddress: recipientAddress,
    );

    if (result.isFailure) {
      final failure = result as Failure<ChainTransaction>;
      return Result.failure(
        failure.error,
        code: failure.code,
        details: failure.details,
      );
    }

    final chainTx = (result as Success<ChainTransaction>).value;
    if (chainTx is! EvmTransaction) {
      return Result.failure('Expected EvmTransaction from ParaSwap');
    }

    final evmTx = chainTx;
    return Result.success(SwapTransaction(
      from: evmTx.from,
      to: evmTx.to,
      data: evmTx.data,
      value: evmTx.value,
      gasLimit: evmTx.gasLimit,
      gasPrice: evmTx.gasPrice,
      chainId: evmTx.chainId,
      metadata: {'summary': evmTx.summary.toString()},
    ));
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.failure(
      'Status check not supported for ParaSwap. Monitor chain for txHash: $txHash',
      code: 'NOT_SUPPORTED',
    );
  }

  @override
  Future<Result<ApprovalMethod>> getApprovalMethod({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
    required BigInt amount,
  }) async {
    try {
      // 1. Check allowance
      final allowanceResult = await checkAllowance(
        chainId: chainId,
        tokenAddress: tokenAddress,
        ownerAddress: ownerAddress,
      );

      if (allowanceResult.isFailure) {
        return Result.failure(allowanceResult.errorOrNull!);
      }

      final allowance = allowanceResult.valueOrNull!;
      if (allowance >= amount) {
        return Result.success(
            NoApprovalNeeded(reason: 'Sufficient allowance already granted'));
      }

      // 2. Fetch spender address
      final spenderResult = await getSpenderAddress(chainId);
      if (spenderResult.isFailure) {
        return Result.failure(spenderResult.errorOrNull!);
      }
      final spender = spenderResult.valueOrNull!;

      // 3. Construct approval transaction manually (ERC20 approve)
      // selector: 0x095ea7b3
      // spender: 32 bytes padded
      // amount: 32 bytes padded

      final spenderPadded = spender.replaceFirst('0x', '').padLeft(64, '0');
      final amountPadded = amount.toRadixString(16).padLeft(64, '0');
      final data = '0x095ea7b3$spenderPadded$amountPadded';

      final tx = EvmTransaction(
        from: ownerAddress,
        to: tokenAddress,
        data: data,
        value: BigInt.zero,
        gasLimit: BigInt.from(60000), // Standard approval gas
        gasPrice: BigInt.zero, // Let wallet estimate or fetch if needed
        chainId: chainId,
        summary: TransactionSummary(
          action: 'Approve',
          fromAsset: tokenAddress,
          toAsset: tokenAddress,
          inputAmount: Decimal.zero,
          expectedOutput: Decimal.zero,
          protocol: name,
        ),
      );

      return Result.success(StandardApproval(
        transaction: tx,
        tokenAddress: tokenAddress,
        spenderAddress: spender,
        amount: amount,
      ));
    } catch (e) {
      return Result.failure('Unexpected error in getApprovalMethod: $e');
    }
  }

  @override
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    try {
      final spenderResult = await getSpenderAddress(chainId);
      if (spenderResult.isFailure) {
        return Result.failure(spenderResult.errorOrNull!);
      }

      final response = await _dio.get(
        '$_baseUrl/allowances/${chainId.id}',
        queryParameters: {
          'userAddress': ownerAddress,
          'tokenAddress': tokenAddress,
          'spenderAddress': spenderResult.valueOrNull,
        },
      );

      final allowance = BigInt.parse(
        response.data['allowance']?.toString() ?? '0',
      );
      return Result.success(allowance);
    } on DioException catch (e) {
      return Result.failure(
        'Failed to check allowance: ${e.message}',
        code: 'ALLOWANCE_ERROR',
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  @override
  @deprecated
  Future<Result<ApprovalTransaction>> getApprovalTransaction({
    required ChainId chainId,
    required String tokenAddress,
    BigInt? amount,
  }) async {
    try {
      final spenderResult = await getSpenderAddress(chainId);
      if (spenderResult.isFailure) {
        return Result.failure(spenderResult.errorOrNull!);
      }

      final approvalAmount = amount ??
          BigInt.parse(
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
            radix: 16,
          );

      final spender = spenderResult.valueOrNull!;
      final spenderPadded = spender.replaceFirst('0x', '').padLeft(64, '0');
      final amountPadded = approvalAmount.toRadixString(16).padLeft(64, '0');
      final data = '0x095ea7b3$spenderPadded$amountPadded';

      final tx = SwapTransaction(
        from: '',
        to: tokenAddress,
        data: data,
        value: BigInt.zero,
        gasLimit: BigInt.from(60000),
        gasPrice: BigInt.zero,
        chainId: chainId,
        metadata: {},
      );

      return Result.success(
        ApprovalTransaction(
          chainId: chainId,
          tokenAddress: tokenAddress,
          spenderAddress: spender,
          amount: approvalAmount,
          transaction: tx,
        ),
      );
    } catch (e) {
      return Result.failure('Failed to get approval: $e');
    }
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    try {
      final response = await _dio.get('$_baseUrl/adapters/${chainId.id}');
      final proxy = response.data['tokenTransferProxy'] as String?;

      if (proxy == null) {
        return Result.failure(
          'Token transfer proxy not found',
          code: 'PROXY_NOT_FOUND',
        );
      }

      return Result.success(proxy);
    } on DioException catch (e) {
      return Result.failure(
        'Failed to get spender address: ${e.message}',
        code: 'SPENDER_ERROR',
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> priceRoute, SwapParams params) {
    final srcAmount = Decimal.fromBigInt(
      BigInt.parse(priceRoute['srcAmount'] ?? '0'),
    );
    final destAmount = Decimal.fromBigInt(
      BigInt.parse(priceRoute['destAmount'] ?? '0'),
    );

    final srcDivisor = Decimal.fromBigInt(
      BigInt.from(10).pow(params.fromTokenDecimals),
    );
    final destDivisor = Decimal.fromBigInt(
      BigInt.from(10).pow(params.toTokenDecimals),
    );

    final inputAmount = (srcAmount / srcDivisor).toDecimal();
    final outputAmount = (destAmount / destDivisor).toDecimal();
    final minOutput = outputAmount *
        (Decimal.one -
            Decimal.parse('0.01') * Decimal.parse(params.slippage.toString()));

    final exchangeRate =
        inputAmount > Decimal.zero ? outputAmount / inputAmount : Decimal.zero;

    final gasLimit = BigInt.parse(priceRoute['gasCost']?.toString() ?? '0');
    final gasPrice = BigInt.parse(priceRoute['gasPrice']?.toString() ?? '0');

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      minimumOutputAmount: minOutput,
      exchangeRate: Decimal.parse(exchangeRate.toString()),
      routes: _parseRoutes(priceRoute['bestRoute']),
      gasEstimate: GasEstimate.fromWei(
        gasLimit: gasLimit,
        gasPrice: gasPrice,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: _calculatePriceImpact(priceRoute),
      protocols: _extractProtocols(priceRoute['bestRoute']),
      validUntil:
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60, // 1 minute
      timestamp: DateTime.now(),
      metadata: {'priceRoute': priceRoute},
    );
  }

  List<SwapRoute> _parseRoutes(dynamic bestRoute) {
    if (bestRoute == null || bestRoute is! List) return [];

    return bestRoute.map<SwapRoute>((route) {
      final swaps = route['swaps'] as List? ?? [];
      final steps = <SwapStep>[];

      for (final swap in swaps) {
        if (swap is Map && swap['swapExchanges'] is List) {
          for (final exchange in swap['swapExchanges']) {
            steps.add(
              SwapStep(
                fromToken: swap['srcToken']?.toString() ?? '',
                toToken: swap['destToken']?.toString() ?? '',
                protocol: exchange['exchange']?.toString() ?? '',
                expectedOutput: Decimal.parse(
                  exchange['destAmount']?.toString() ?? '0',
                ),
              ),
            );
          }
        }
      }

      return SwapRoute(
        protocol: 'ParaSwap',
        portion: double.parse(route['percent']?.toString() ?? '100'),
        steps: steps,
      );
    }).toList();
  }

  List<String> _extractProtocols(dynamic bestRoute) {
    if (bestRoute == null || bestRoute is! List) return [];

    final protocols = <String>{};
    for (final route in bestRoute) {
      if (route is Map && route['swaps'] is List) {
        for (final swap in route['swaps']) {
          if (swap is Map && swap['swapExchanges'] is List) {
            for (final exchange in swap['swapExchanges']) {
              if (exchange is Map && exchange['exchange'] != null) {
                protocols.add(exchange['exchange'].toString());
              }
            }
          }
        }
      }
    }
    return protocols.toList();
  }

  double _calculatePriceImpact(Map<String, dynamic> priceRoute) {
    try {
      final srcUSD =
          double.tryParse(priceRoute['srcUSD']?.toString() ?? '0') ?? 0;
      final destUSD =
          double.tryParse(priceRoute['destUSD']?.toString() ?? '0') ?? 0;

      if (srcUSD > 0 && destUSD > 0) {
        return ((srcUSD - destUSD) / srcUSD).abs() * 100;
      }
      return 0.0;
    } catch (e) {
      return 0.0;
    }
  }
}
