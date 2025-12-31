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

/// OpenOcean API v4 Provider
///
/// OpenOcean offers free public API access.
/// API keys are optional for higher rate limits.
///
/// API Documentation: https://docs.openocean.finance/
///
/// ## Example
/// ```dart
/// final openocean = OpenOceanProvider();
/// final quote = await openocean.getQuote(params);
/// ```
class OpenOceanProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://open-api.openocean.finance/v4';

  final Dio _dio;
  final String? _apiKey;

  OpenOceanProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_apiKey != null) 'apiKey': _apiKey,
    };
  }

  @override
  String get name => 'OpenOcean';

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
        ChainId.linea,
        ChainId.zksync,
      ];

  @override
  bool get supportsCrossChain => false;

  String _getChainName(ChainId chainId) {
    switch (chainId) {
      case ChainId.ethereum:
        return 'eth';
      case ChainId.polygon:
        return 'polygon';
      case ChainId.bsc:
        return 'bsc';
      case ChainId.arbitrum:
        return 'arbitrum';
      case ChainId.optimism:
        return 'optimism';
      case ChainId.avalanche:
        return 'avax';
      case ChainId.fantom:
        return 'fantom';
      case ChainId.base:
        return 'base';
      case ChainId.linea:
        return 'linea';
      case ChainId.zksync:
        return 'zksync';
      default:
        return 'eth';
    }
  }

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      final chainName = _getChainName(chainId);
      final response = await _dio.get('$_baseUrl/$chainName/tokenList');

      final data = response.data;
      if (data['data'] != null && data['data'] is List) {
        final tokens = (data['data'] as List)
            .map((t) => Token.fromJson(t as Map<String, dynamic>, chainId))
            .toList();
        return Result.success(tokens);
      }
      return Result.success([]);
    } on DioException catch (e) {
      return Result.failure(
        'Failed to fetch tokens: ${e.message}',
        code: 'TOKENS_FETCH_ERROR',
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final chainName = _getChainName(params.fromChain);
      // v4 API uses amountDecimals instead of amount
      final queryParams = {
        'inTokenAddress': params.fromTokenAddress,
        'outTokenAddress': params.toTokenAddress,
        'amount': params.amountInSmallestUnit.toString(),
        'slippage': params.slippage.toString(),
        'account': params.userAddress,
        'gasPrice': '5000000000', // 5 gwei default
      };

      final response = await _dio.get(
        '$_baseUrl/$chainName/quote',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data['code'] != 200) {
        return Result.failure(
          data['error'] ?? 'Failed to get quote',
          code: 'QUOTE_ERROR',
        );
      }

      final quote = _parseQuote(data['data'], params);
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
      final chainName = _getChainName(quote.params.fromChain);
      final queryParams = {
        'inTokenAddress': quote.params.fromTokenAddress,
        'outTokenAddress': quote.params.toTokenAddress,
        'amount': quote.params.amount.toString(),
        'account': userAddress,
        'slippage': quote.params.slippage.toString(),
        'gasPrice': '5', // Default gas price for build
        if (recipientAddress != null) 'referrer': recipientAddress,
      };

      final response = await _dio.get(
        '$_baseUrl/$chainName/swap_quote',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data['code'] != 200) {
        return Result.failure(
          data['error'] ?? 'Failed to build transaction',
          code: 'TX_BUILD_ERROR',
        );
      }

      final txData = data['data'];

      // Add 35% safety buffer for gas
      final estimatedGas = int.parse(
        txData['estimatedGas']?.toString() ?? '500000',
      );
      final gasWithBuffer = (estimatedGas * 1.35).round();

      final tx = EvmTransaction(
        from: txData['from'] ?? userAddress,
        to: txData['to'],
        data: txData['data'],
        value: BigInt.parse(txData['value']?.toString() ?? '0'),
        gasLimit: BigInt.from(gasWithBuffer),
        gasPrice: BigInt.parse(txData['gasPrice']?.toString() ?? '0'),
        chainId: quote.params.fromChain,
        metadata: txData,
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
      return Result.failure(failure.error,
          code: failure.code, details: failure.details);
    }

    final evmTx = (result as Success<ChainTransaction>).value as EvmTransaction;
    return Result.success(SwapTransaction(
      from: evmTx.from,
      to: evmTx.to,
      data: evmTx.data,
      value: evmTx.value,
      gasLimit: evmTx.gasLimit,
      gasPrice: evmTx.gasPrice,
      chainId: evmTx.chainId,
      metadata: evmTx.metadata,
    ));
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.failure(
      'Status check not supported for OpenOcean. Monitor chain for txHash: $txHash',
      code: 'NOT_SUPPORTED',
    );
  }

  @override
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    try {
      final chainName = _getChainName(chainId);
      final response = await _dio.get(
        '$_baseUrl/$chainName/allowance',
        queryParameters: {
          'account': ownerAddress,
          'inTokenAddress': tokenAddress,
        },
      );

      final data = response.data;
      if (data['code'] == 200) {
        final allowance = BigInt.parse(data['data']?.toString() ?? '0');
        return Result.success(allowance);
      }
      return Result.success(BigInt.zero);
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
  Future<Result<ApprovalMethod>> getApprovalMethod({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
    required BigInt amount,
  }) async {
    try {
      if (tokenAddress.toLowerCase().contains('eeee') ||
          tokenAddress == 'native') {
        return Result.success(
            NoApprovalNeeded(reason: 'Native asset does not require approval'));
      }

      // 1. Check current allowance
      final allowanceResult = await checkAllowance(
        chainId: chainId,
        tokenAddress: tokenAddress,
        ownerAddress: ownerAddress,
      );

      if (allowanceResult.isSuccess &&
          (allowanceResult.valueOrNull ?? BigInt.zero) >= amount) {
        return Result.success(
            NoApprovalNeeded(reason: 'Existing allowance is sufficient'));
      }

      // 2. Fetch approval transaction from API
      final chainName = _getChainName(chainId);
      final response = await _dio.get(
        '$_baseUrl/$chainName/approve',
        queryParameters: {
          'inTokenAddress': tokenAddress,
          'amount': amount.toString(),
        },
      );

      final data = response.data;
      if (data['code'] != 200) {
        return Result.failure(
          data['error'] ?? 'Failed to get approval',
          code: 'APPROVAL_ERROR',
        );
      }

      final txData = data['data'];
      final spender = txData['to'] ?? '';

      final tx = EvmTransaction(
        from: ownerAddress,
        to: spender,
        data: txData['data'] ?? '',
        value: BigInt.zero,
        gasLimit: BigInt.from(60000),
        gasPrice: BigInt.zero,
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
    } on DioException catch (e) {
      return Result.failure(
        'Failed to get approval method: ${e.message}',
        code: 'APPROVAL_ERROR',
        details: e.response?.data,
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
    final result = await getApprovalMethod(
      chainId: chainId,
      tokenAddress: tokenAddress,
      ownerAddress: '',
      amount: amount ??
          BigInt.parse(
              'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
              radix: 16),
    );

    if (result.isFailure) {
      return Result.failure(result.errorOrNull!);
    }

    final method = result.valueOrNull;
    if (method is StandardApproval) {
      final tx = method.transaction;
      return Result.success(ApprovalTransaction(
        chainId: chainId,
        tokenAddress: tokenAddress,
        spenderAddress: method.spenderAddress,
        amount: method.amount,
        transaction: SwapTransaction(
          from: tx.from,
          to: tx.to,
          data: tx.data,
          value: tx.value,
          gasLimit: tx.gasLimit,
          gasPrice: tx.gasPrice,
          chainId: tx.chainId,
        ),
      ));
    }

    return Result.failure('No approval transaction needed or available');
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    // OpenOcean uses a universal exchange contract
    // The actual address is returned in the approval transaction
    return Result.success('0x6352a56caadC4F1E25CD6c75970Fa768A3304e64');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final inputAmount = Decimal.parse(data['inAmount']?.toString() ?? '0');
    final outputAmount = Decimal.parse(data['outAmount']?.toString() ?? '0');
    final minOutput = outputAmount *
        (Decimal.one -
            Decimal.parse('0.01') * Decimal.parse(params.slippage.toString()));

    final exchangeRate =
        inputAmount > Decimal.zero ? outputAmount / inputAmount : Decimal.zero;

    final gasLimit = BigInt.parse(data['estimatedGas']?.toString() ?? '200000');

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      minimumOutputAmount: minOutput,
      exchangeRate: Decimal.parse(exchangeRate.toString()),
      routes: _parseRoutes(data['path']),
      gasEstimate: GasEstimate.fromWei(
        gasLimit: gasLimit,
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact:
          double.tryParse(data['priceImpact']?.toString() ?? '0') ?? 0.0,
      protocols: _extractProtocols(data['path']),
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }

  List<SwapRoute> _parseRoutes(dynamic path) {
    if (path == null || path is! List) return [];

    return path.map<SwapRoute>((p) {
      final steps = <SwapStep>[];
      if (p is Map && p['routes'] is List) {
        for (final route in p['routes']) {
          if (route is Map) {
            steps.add(
              SwapStep(
                fromToken: route['inToken']?['address']?.toString() ?? '',
                toToken: route['outToken']?['address']?.toString() ?? '',
                protocol: route['dex']?.toString() ?? '',
                expectedOutput: Decimal.zero,
              ),
            );
          }
        }
      }

      return SwapRoute(
        protocol: p['dex']?.toString() ?? 'OpenOcean',
        portion: double.tryParse(p['portion']?.toString() ?? '100') ?? 100,
        steps: steps,
      );
    }).toList();
  }

  List<String> _extractProtocols(dynamic path) {
    if (path == null || path is! List) return [];

    final protocols = <String>{};
    for (final p in path) {
      if (p is Map && p['dex'] != null) {
        protocols.add(p['dex'].toString());
      }
    }
    return protocols.toList();
  }
}
