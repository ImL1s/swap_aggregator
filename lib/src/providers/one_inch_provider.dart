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

/// 1inch API v6.0 Provider
///
/// Requires an API key for production use.
/// Get your API key at https://portal.1inch.dev/
///
/// API Documentation: https://portal.1inch.dev/documentation/swap/swagger
///
/// ## Example
/// ```dart
/// final oneInch = OneInchProvider(apiKey: 'your-api-key');
/// final quote = await oneInch.getQuote(params);
/// ```
class OneInchProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.1inch.dev/swap/v6.0';

  final Dio _dio;
  final String? _apiKey;

  /// Create a 1inch provider
  ///
  /// [apiKey] is required for production use.
  /// [dio] can be provided for custom HTTP configuration.
  OneInchProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_apiKey != null) 'Authorization': 'Bearer $_apiKey',
    };
  }

  @override
  String get name => '1inch';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.polygon,
        ChainId.bsc,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.avalanche,
        ChainId.gnosis,
        ChainId.fantom,
        ChainId.base,
        ChainId.zksync,
      ];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      final response = await _dio.get('$_baseUrl/${chainId.id}/tokens');

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
      // v6.0 API uses different parameter names
      final queryParams = {
        'src': params.fromTokenAddress,
        'dst': params.toTokenAddress,
        'amount': params.amountInSmallestUnit.toString(),
        'from': params.userAddress,
        'slippage': params.slippage.toString(),
        'includeTokensInfo': 'true',
        'includeProtocols': 'true',
        'includeGas': 'true',
      };

      final response = await _dio.get(
        '$_baseUrl/${params.fromChain.id}/quote',
        queryParameters: queryParams,
      );

      final data = response.data;
      final quote = _parseQuote(data, params);
      return Result.success(quote);
    } on DioException catch (e) {
      if (e.response?.statusCode == 429) {
        return Result.failure(
          'Rate limit exceeded. Please try again later.',
          code: 'RATE_LIMIT',
        );
      }
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
      // v6.0 API swap endpoint
      final queryParams = {
        'src': quote.params.fromTokenAddress,
        'dst': quote.params.toTokenAddress,
        'amount': quote.params.amountInSmallestUnit.toString(),
        'from': userAddress,
        'slippage': quote.params.slippage.toString(),
        'origin': userAddress,
        if (recipientAddress != null) 'receiver': recipientAddress,
      };

      final response = await _dio.get(
        '$_baseUrl/${quote.params.fromChain.id}/swap',
        queryParameters: queryParams,
      );

      final data = response.data;
      final txData = data['tx'] as Map<String, dynamic>;

      final tx = EvmTransaction(
        from: txData['from'] ?? userAddress,
        to: txData['to'],
        data: txData['data'],
        value: BigInt.parse(txData['value']?.toString() ?? '0'),
        gasLimit: BigInt.parse(txData['gas']?.toString() ?? '500000'),
        gasPrice: BigInt.parse(txData['gasPrice']?.toString() ?? '0'),
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
      return Result.failure('Expected EvmTransaction from 1inch');
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
      'Status check not supported for 1inch. Monitor chain for txHash: $txHash',
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

      // 2. Fetch approval transaction if needed
      final spenderResult = await getSpenderAddress(chainId);
      if (spenderResult.isFailure) {
        return Result.failure(spenderResult.errorOrNull!);
      }
      final spender = spenderResult.valueOrNull!;

      final queryParams = <String, dynamic>{'tokenAddress': tokenAddress};
      if (amount > BigInt.zero) {
        queryParams['amount'] = amount.toString();
      }

      final response = await _dio.get(
        '$_baseUrl/${chainId.id}/approve/transaction',
        queryParameters: queryParams,
      );

      final data = response.data;
      final tx = EvmTransaction(
        from: ownerAddress,
        to: data['to'],
        data: data['data'],
        value: BigInt.parse(data['value']?.toString() ?? '0'),
        gasLimit: BigInt.parse(data['gas']?.toString() ?? '100000'),
        gasPrice: BigInt.parse(data['gasPrice']?.toString() ?? '0'),
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
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/${chainId.id}/approve/allowance',
        queryParameters: {
          'tokenAddress': tokenAddress,
          'walletAddress': ownerAddress,
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
    final result = await getSpenderAddress(chainId);
    if (result.isFailure) return Result.failure(result.errorOrNull!);

    final spender = result.valueOrNull!;
    // Use a dummy owner address since V1 signature didn't require it but V2 does.
    // This is valid because getApprovalMethod will just fetch the tx data which is generic
    // (except for 'from' field which we might need to handle, but 1inch approve endpoint doesn't strictly require 'from' for just data)
    // However, getApprovalMethod relies on checkAllowance which needs owner.
    // The V1 method signature is flawed as it relies on 'getApprovalTransaction' which takes no owner,
    // assuming the API doesn't need it or implementation has it stored.
    // But OneInchProvider doesn't store state.
    // We'll keep the existing implementation logic for V1 to be safe, just deprecated.

    try {
      final queryParams = <String, dynamic>{'tokenAddress': tokenAddress};
      if (amount != null) {
        queryParams['amount'] = amount.toString();
      }

      final response = await _dio.get(
        '$_baseUrl/${chainId.id}/approve/transaction',
        queryParameters: queryParams,
      );

      final data = response.data;

      final approvalAmount = amount ??
          BigInt.parse(
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
            radix: 16,
          );

      final tx = SwapTransaction(
        from: '',
        to: data['to'],
        data: data['data'],
        value: BigInt.zero,
        gasLimit: BigInt.parse(
            data['gas']?.toString() ?? '50000'), // 'gas' field often used now
        gasPrice: BigInt.parse(data['gasPrice']?.toString() ?? '0'),
        chainId: chainId,
        metadata: data,
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
      return Result.failure('Error in deprecated getApprovalTransaction: $e');
    }
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/${chainId.id}/approve/spender',
      );

      final spender = response.data['address'] as String?;
      if (spender == null) {
        return Result.failure(
          'Spender address not found',
          code: 'SPENDER_NOT_FOUND',
        );
      }

      return Result.success(spender);
    } on DioException catch (e) {
      return Result.failure(
        'Failed to get spender address: ${e.message}',
        code: 'SPENDER_ERROR',
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final srcAmount = Decimal.fromBigInt(
      BigInt.parse(data['fromTokenAmount']?.toString() ?? '0'),
    );
    final destAmount = Decimal.fromBigInt(
      BigInt.parse(data['toTokenAmount']?.toString() ?? '0'),
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

    final exchangeRate = inputAmount > Decimal.zero
        ? (outputAmount / inputAmount).toDecimal()
        : Decimal.zero;

    final gasLimit = BigInt.parse(data['estimatedGas']?.toString() ?? '200000');

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      minimumOutputAmount: minOutput,
      exchangeRate: exchangeRate,
      routes: _parseRoutes(data['protocols']),
      gasEstimate: GasEstimate.fromWei(
        gasLimit: gasLimit,
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: 0.0, // 1inch doesn't provide price impact in quote
      protocols: _extractProtocols(data['protocols']),
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }

  List<SwapRoute> _parseRoutes(dynamic protocols) {
    if (protocols == null || protocols is! List) return [];

    final routes = <SwapRoute>[];
    for (final protocol in protocols) {
      if (protocol is List) {
        for (final route in protocol) {
          if (route is List) {
            final steps = route
                .where((step) => step is Map)
                .map<SwapStep>(
                  (step) => SwapStep(
                    fromToken: step['fromTokenAddress']?.toString() ?? '',
                    toToken: step['toTokenAddress']?.toString() ?? '',
                    protocol: step['name']?.toString() ?? '',
                    expectedOutput: Decimal.zero,
                  ),
                )
                .toList();

            if (steps.isNotEmpty) {
              routes.add(
                SwapRoute(
                  protocol: steps.first.protocol,
                  portion: 100.0 / (protocols.length),
                  steps: steps,
                ),
              );
            }
          }
        }
      }
    }
    return routes;
  }

  List<String> _extractProtocols(dynamic protocols) {
    if (protocols == null || protocols is! List) return [];

    final result = <String>{};
    for (final protocol in protocols) {
      if (protocol is List) {
        for (final route in protocol) {
          if (route is List) {
            for (final step in route) {
              if (step is Map && step['name'] != null) {
                result.add(step['name'].toString());
              }
            }
          }
        }
      }
    }
    return result.toList();
  }
}
