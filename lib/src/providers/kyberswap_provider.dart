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

/// KyberSwap Aggregator Provider
///
/// Uses KyberSwap Aggregator API for multi-chain swaps.
/// API Docs: https://docs.kyberswap.com/kyBERSWAP-solutions/kyberswap-aggregator/aggregator-api-specification/evm-swaps
///
/// ## Example
/// ```dart
/// final kyber = KyberSwapProvider();
/// final quote = await kyber.getQuote(params);
/// ```
class KyberSwapProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://aggregator-api.kyberswap.com';

  final Dio _dio;
  final String? _apiKey;

  KyberSwapProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_apiKey != null) 'x-client-id': _apiKey,
    };
  }

  @override
  String get name => 'KyberSwap';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.bsc,
        ChainId.polygon,
        ChainId.avalanche,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.fantom,
        ChainId.base,
        ChainId.linea,
        ChainId.zksync,
        ChainId.scroll,
        ChainId.blast,
        ChainId.mantle,
      ];

  @override
  bool get supportsCrossChain => false;

  String _getChainName(ChainId chainId) {
    // KyberSwap chain paths
    switch (chainId) {
      case ChainId.ethereum:
        return 'ethereum';
      case ChainId.bsc:
        return 'bsc';
      case ChainId.polygon:
        return 'polygon';
      case ChainId.avalanche:
        return 'avalanche';
      case ChainId.arbitrum:
        return 'arbitrum';
      case ChainId.optimism:
        return 'optimism';
      case ChainId.fantom:
        return 'fantom';
      case ChainId.base:
        return 'base';
      case ChainId.linea:
        return 'linea';
      case ChainId.zksync:
        return 'zksync';
      case ChainId.scroll:
        return 'scroll';
      case ChainId.blast:
        return 'blast';
      case ChainId.mantle:
        return 'mantle';
      default:
        return 'ethereum';
    }
  }

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // KyberSwap doesn't provide a simple all-tokens list for free public use efficiently
    // It's better to rely on external token lists or wallet defaults
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final chainName = _getChainName(params.fromChain);
      final queryParams = {
        'tokenIn': params.fromTokenAddress,
        'tokenOut': params.toTokenAddress,
        'amountIn': params.amountInSmallestUnit.toString(),
        'saveGas': 0, // 0 = max return, 1 = save gas
        'gasInclude': 0, // 0 = false, 1 = true
      };

      final response = await _dio.get(
        '$_baseUrl/$chainName/api/v1/routes',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data['code'] != 0) {
        return Result.failure(
          data['message'] ?? 'Failed to get quote',
          code: 'QUOTE_ERROR',
        );
      }

      final routeSummary = data['data']['routeSummary'];
      if (routeSummary == null) {
        return Result.failure('No route found', code: 'NO_ROUTE');
      }

      return Result.success(_parseQuote(routeSummary, params, chainName));
    } on DioException catch (e) {
      return Result.failure(
        'KyberSwap quote failed: ${e.message}',
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
      final routeSummary = quote.metadata['routeSummary'];

      if (routeSummary == null) {
        return Result.failure('Missing route summary in quote');
      }

      final body = {
        'routeSummary': routeSummary,
        'sender': userAddress,
        'recipient': recipientAddress ?? userAddress,
        'slippageTolerance': (quote.params.slippage * 100).toInt(), // bps
      };

      final response = await _dio.post(
        '$_baseUrl/$chainName/api/v1/route/build',
        data: body,
      );

      final data = response.data;
      if (data['code'] != 0) {
        return Result.failure(
          data['message'] ?? 'Failed to build transaction',
          code: 'TX_BUILD_ERROR',
        );
      }

      final txData = data['data'];
      final encodedData = txData['data'] as String;
      final routerAddress = txData['routerAddress'] as String;

      // Add safety buffer for gas (35%)
      // Kyber usually provides gas in route summary
      final routeGas =
          BigInt.parse(routeSummary['gas']?.toString() ?? '500000');
      final gasWithBuffer = (routeGas.toInt() * 1.35).round();

      final tx = EvmTransaction(
        from: userAddress,
        to: routerAddress,
        data: encodedData,
        value: BigInt.parse(txData['amountIn']?.toString() ?? '0'),
        gasLimit: BigInt.from(gasWithBuffer),
        gasPrice: BigInt.zero, // EIP-1559 usually handled by wallet
        chainId: quote.params.fromChain,
        summary: TransactionSummary(
          action: 'Swap',
          fromAsset: quote.params.fromToken,
          toAsset: quote.params.toToken,
          inputAmount: quote.inputAmount,
          expectedOutput: quote.outputAmount,
          protocol: name,
        ),
        metadata: data,
      );

      return Result.success(tx);
    } on DioException catch (e) {
      return Result.failure(
        'KyberSwap tx build failed: ${e.message}',
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
      'Status check not supported for KyberSwap. Monitor chain for txHash: $txHash',
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
  Future<Result<ApprovalMethod>> getApprovalMethod({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
    required BigInt amount,
  }) async {
    if (tokenAddress.toLowerCase() == 'native' ||
        tokenAddress == '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE') {
      return Result.success(NoApprovalNeeded(reason: 'Native asset'));
    }

    final spenderResult = await getSpenderAddress(chainId);
    if (spenderResult.isFailure)
      return Result.failure(spenderResult.errorOrNull!);

    final tx = EvmTransaction(
      from: ownerAddress,
      to: tokenAddress,
      data: '0x095ea7b3' // approve(address,uint256)
          '${spenderResult.valueOrNull!.replaceAll('0x', '').padLeft(64, '0')}'
          '${amount.toRadixString(16).padLeft(64, '0')}',
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
      spenderAddress: spenderResult.valueOrNull!,
      amount: amount,
    ));
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

    if (result.isFailure) return Result.failure(result.errorOrNull!);

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
    return Result.failure('No approval needed');
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    // MetaAggregationRouterV2 address is constant across most EVM chains
    // Verify based on documentation if it differs per chain.
    // For simplicity, using the common Router V2 address.
    return Result.success('0x6131B5fae19EA4f9D964eAc0408E4408b66337b5');
  }

  SwapQuote _parseQuote(
    Map<String, dynamic> routeSummary,
    SwapParams params,
    String chainName,
  ) {
    final amountIn = BigInt.parse(routeSummary['amountIn']?.toString() ?? '0');
    final amountOut =
        BigInt.parse(routeSummary['amountOut']?.toString() ?? '0');

    final decimalIn = (Decimal.fromBigInt(amountIn) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.fromTokenDecimals)))
        .toDecimal();

    final decimalOut = (Decimal.fromBigInt(amountOut) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.toTokenDecimals)))
        .toDecimal();

    final exchangeRate = decimalIn > Decimal.zero
        ? (decimalOut / decimalIn).toDecimal()
        : Decimal.zero;

    final gasEstimate = BigInt.parse(routeSummary['gas']?.toString() ?? '0');

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: decimalIn,
      outputAmount: decimalOut,
      minimumOutputAmount: decimalOut *
          (Decimal.one -
              Decimal.parse('0.01') *
                  Decimal.parse(params.slippage.toString())),
      exchangeRate: exchangeRate,
      routes: [], // Detailed route parsing omitted for brevity
      gasEstimate: GasEstimate.fromWei(
        gasLimit: gasEstimate,
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: 0.0, // Calculated field often not directly in summary
      protocols: ['KyberSwap'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: {'routeSummary': routeSummary, 'chainName': chainName},
    );
  }
}
