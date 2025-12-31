import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../core/models/chain_id.dart';
import '../core/models/gas_estimate.dart';
import '../core/models/swap_params.dart';
import '../core/models/swap_quote.dart';
import '../core/models/swap_status.dart';
import '../core/models/swap_transaction.dart';
import '../core/models/token.dart';
import '../core/swap_provider_interface.dart';
import '../utils/result.dart';

/// Uniswap Trading API Provider (V2/V3/V4)
///
/// Uses the Uniswap Trading API for quotes and swaps.
/// Supports V2, V3, and V4 protocols via unified `/quote` endpoint.
///
/// API Documentation: https://docs.uniswap.org/api/
/// Router: UniswapV2Router02 (0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D)
/// Universal Router: 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD
///
/// ## Example
/// ```dart
/// final uniswap = UniswapProvider(apiKey: 'your-api-key');
/// final quote = await uniswap.getQuote(params);
/// ```
class UniswapProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.uniswap.org/v2';

  final Dio _dio;
  final String? _apiKey;

  UniswapProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Origin': 'https://app.uniswap.org',
      if (_apiKey != null) 'x-api-key': _apiKey,
    };
  }

  @override
  String get name => 'Uniswap';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.polygon,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.base,
      ];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // Uniswap doesn't provide a public token list API
    // Use Uniswap token lists from IPFS/GitHub instead
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final body = {
        'tokenInChainId': params.fromChain.id,
        'tokenIn': params.fromTokenAddress,
        'tokenOutChainId': params.toChain.id,
        'tokenOut': params.toTokenAddress,
        'amount': params.amountInSmallestUnit.toString(),
        'type': 'EXACT_INPUT',
        'recipient': params.userAddress,
        'slippageTolerance': params.slippage / 100,
        'deadline': DateTime.now()
                .add(const Duration(minutes: 20))
                .millisecondsSinceEpoch ~/
            1000,
      };

      final response = await _dio.post('$_baseUrl/quote', data: body);

      final data = response.data;
      if (data['quote'] == null) {
        return Result.failure('No quote available', code: 'NO_QUOTE');
      }

      final quote = _parseQuote(data, params);
      return Result.success(quote);
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        return Result.failure(
          'Quote conflict - please retry',
          code: 'CONFLICT',
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
  Future<Result<SwapTransaction>> buildTransaction({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    // Uniswap returns transaction data in the quote response
    final txData = quote.metadata;

    try {
      final methodParameters = txData['methodParameters'];
      if (methodParameters == null) {
        return Result.failure(
          'No transaction data in quote',
          code: 'MISSING_TX_DATA',
        );
      }

      final tx = SwapTransaction(
        from: userAddress,
        to: methodParameters['to'] ?? '',
        data: methodParameters['calldata'] ?? '',
        value: BigInt.parse(methodParameters['value']?.toString() ?? '0'),
        gasLimit: BigInt.parse(txData['gasEstimate']?.toString() ?? '300000'),
        gasPrice: BigInt.zero,
        chainId: quote.params.fromChain,
        metadata: txData,
      );

      return Result.success(tx);
    } catch (e) {
      return Result.failure('Failed to build transaction: $e');
    }
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.failure(
      'Status check not supported for Uniswap. Monitor chain for txHash: $txHash',
      code: 'NOT_SUPPORTED',
    );
  }

  @override
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    // Caller should check on-chain
    return Result.success(BigInt.zero);
  }

  @override
  Future<Result<ApprovalTransaction>> getApprovalTransaction({
    required ChainId chainId,
    required String tokenAddress,
    BigInt? amount,
  }) async {
    final spenderResult = await getSpenderAddress(chainId);
    if (spenderResult.isFailure) {
      return Result.failure(spenderResult.errorOrNull!);
    }

    final approvalAmount = amount ??
        BigInt.parse(
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
          radix: 16,
        );

    return Result.success(
      ApprovalTransaction(
        chainId: chainId,
        tokenAddress: tokenAddress,
        spenderAddress: spenderResult.valueOrNull!,
        amount: approvalAmount,
      ),
    );
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    // Uniswap Universal Router addresses
    switch (chainId) {
      case ChainId.ethereum:
        return Result.success('0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD');
      case ChainId.polygon:
        return Result.success('0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD');
      case ChainId.arbitrum:
        return Result.success('0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD');
      case ChainId.optimism:
        return Result.success('0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD');
      case ChainId.base:
        return Result.success('0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD');
      default:
        return Result.failure('Unsupported chain');
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final quoteData = data['quote'] ?? data;

    final srcAmount = Decimal.fromBigInt(
      BigInt.parse(
        quoteData['amountIn']?.toString() ??
            params.amountInSmallestUnit.toString(),
      ),
    );
    final destAmount = Decimal.fromBigInt(
      BigInt.parse(quoteData['amountOut']?.toString() ?? '0'),
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

    final gasLimit = BigInt.parse(data['gasEstimate']?.toString() ?? '200000');

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      minimumOutputAmount: minOutput,
      exchangeRate: Decimal.parse(exchangeRate.toString()),
      routes: _parseRoutes(data['route']),
      gasEstimate: GasEstimate.fromWei(
        gasLimit: gasLimit,
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact:
          double.tryParse(data['priceImpact']?.toString() ?? '0') ?? 0.0,
      protocols: _extractProtocols(data['route']),
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }

  List<SwapRoute> _parseRoutes(dynamic route) {
    if (route == null || route is! List) return [];

    return route.map<SwapRoute>((r) {
      final steps = <SwapStep>[];
      if (r is List) {
        for (final pool in r) {
          if (pool is Map) {
            steps.add(
              SwapStep(
                fromToken: pool['tokenIn']?['address']?.toString() ?? '',
                toToken: pool['tokenOut']?['address']?.toString() ?? '',
                protocol: 'Uniswap V${pool['version'] ?? 3}',
                poolAddress: pool['address']?.toString(),
                poolFee: int.tryParse(pool['fee']?.toString() ?? '3000'),
                expectedOutput: Decimal.parse(
                  pool['amountOut']?.toString() ?? '0',
                ),
              ),
            );
          }
        }
      }

      return SwapRoute(protocol: 'Uniswap', portion: 100, steps: steps);
    }).toList();
  }

  List<String> _extractProtocols(dynamic route) {
    if (route == null || route is! List) return ['Uniswap V3'];

    final protocols = <String>{};
    for (final r in route) {
      if (r is List) {
        for (final pool in r) {
          if (pool is Map) {
            final version = pool['version'] ?? 3;
            protocols.add('Uniswap V$version');
          }
        }
      }
    }
    return protocols.isEmpty ? ['Uniswap V3'] : protocols.toList();
  }
}
