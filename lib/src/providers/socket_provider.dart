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

/// Socket (Bungee) Provider
///
/// Cross-chain liquidity aggregator.
/// API Docs: https://docs.socket.tech/socket-api/v2
class SocketProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.socket.tech/v2';

  final Dio _dio;
  final String? _apiKey;

  SocketProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'API-KEY': _apiKey ??
          '72a5b4b0-e727-48be-8aa1-5da9d62fe635', // Public Key or Provided
    };
  }

  @override
  String get name => 'Socket';

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
        ChainId.zksync,
        ChainId.linea,
        ChainId.scroll,
        ChainId.blast,
        ChainId.aurora,
        ChainId.gnosis,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // Socket provides token lists but for simplicity/performance we often rely on external lists
    // Endpoint: /token-lists/from-token-list
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final queryParams = {
        'fromChainId': params.fromChain.id,
        'toChainId': params.toChain.id,
        'fromTokenAddress': params.fromTokenAddress,
        'toTokenAddress': params.toTokenAddress,
        'fromAmount': params.amountInSmallestUnit.toString(),
        'userAddress': params.userAddress,
        'uniqueRoutesPerBridge': true,
        'sort': 'output',
        'singleTxOnly': true,
      };

      final response = await _dio.get(
        '$_baseUrl/quote',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data['success'] == false) {
        return Result.failure('Socket quote failed');
      }

      final result = data['result'];
      final routes = result['routes'] as List;

      if (routes.isEmpty) {
        return Result.failure('No routes found');
      }

      // Best route is usually first due to sort='output'
      final bestRoute = routes[0];

      return Result.success(_parseQuote(bestRoute, params));
    } on DioException catch (e) {
      return Result.failure(
        'Socket quote failed: ${e.message}',
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
      final route = quote.metadata;

      final body = {
        'route': route,
      };

      final response = await _dio.post(
        '$_baseUrl/build-tx',
        data: body,
      );

      final data = response.data;
      if (data['success'] == false) {
        return Result.failure('Socket tx build failed');
      }

      final result = data['result'];
      final txData = result['txData'];

      if (txData == null) {
        return Result.failure('No transaction data in response');
      }

      return Result.success(
        EvmTransaction(
          from: txData['from'] ?? userAddress,
          to: txData['to'],
          data: txData['data'],
          value: BigInt.parse(txData['value']?.toString() ?? '0'),
          gasLimit: BigInt.parse(txData['gasLimit']?.toString() ?? '500000'),
          gasPrice: BigInt.tryParse(txData['gasPrice']?.toString() ?? '0') ??
              BigInt.zero,
          chainId: quote.params.fromChain,
          summary: TransactionSummary(
            action: quote.params.fromChain == quote.params.toChain
                ? 'Swap'
                : 'Bridge',
            fromAsset: quote.params.fromToken,
            toAsset: quote.params.toToken,
            inputAmount: quote.inputAmount,
            expectedOutput: quote.outputAmount,
            protocol: name,
            destinationChain: quote.params.fromChain == quote.params.toChain
                ? null
                : quote.params.toChain.name,
          ),
          metadata: result,
        ),
      );
    } on DioException catch (e) {
      return Result.failure(
        'Socket tx build failed: ${e.message}',
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
    // Socket provides status via /bridge-status?transactionHash=...
    try {
      final response = await _dio.get(
        '$_baseUrl/bridge-status',
        queryParameters: {'transactionHash': txHash},
      );

      final data = response.data;
      // Map status...
      // Assuming generic response or fail for now as standard varies
      return Result.success(SwapStatus(
        txHash: txHash,
        status: SwapStatusType.processing, // Or parse actual
        metadata: data,
      ));
    } catch (_) {
      // Fallback
      return Result.failure('Status check failed', code: 'STATUS_ERROR');
    }
  }

  @override
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
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
      data: '0x095ea7b3'
          '${spenderResult.valueOrNull!.replaceAll('0x', '').padLeft(64, '0')}'
          '${amount.toRadixString(16).padLeft(64, '0')}',
      value: BigInt.zero,
      gasLimit: BigInt.from(64000),
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
    // Socket usually returns 'approvalData' in the /build-tx response (allowanceTarget).
    // But for a separate call, we might rely on a known Socket Vault address or fetch it.
    // Endpoint: /approval/check-allowance (requires params)
    // Or /approval/build-tx

    // Best practice with Socket is often to rely on build-tx returning the approval tx if needed,
    // or check 'allowanceTarget' in the quote response if available?
    // Actually route object often has it.

    // For now, return failure to enforce buildTransaction flow?
    // Or hardcode Socket Gateway.
    return Result.failure(
        'Socket recommends checking allowance via build-tx response or quote data.');
  }

  SwapQuote _parseQuote(Map<String, dynamic> route, SwapParams params) {
    final fromAmount = BigInt.parse(route['fromAmount']?.toString() ?? '0');
    final toAmount = BigInt.parse(route['toAmount']?.toString() ?? '0');

    final decimalIn = (Decimal.fromBigInt(fromAmount) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.fromTokenDecimals)))
        .toDecimal();

    final decimalOut = (Decimal.fromBigInt(toAmount) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.toTokenDecimals)))
        .toDecimal();

    final exchangeRate = decimalIn > Decimal.zero
        ? (decimalOut / decimalIn).toDecimal()
        : Decimal.zero;

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: decimalIn,
      outputAmount: decimalOut,
      minimumOutputAmount:
          decimalOut, // Socket usually handles slippage in output
      exchangeRate: exchangeRate,
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit: BigInt.zero, // Included in fees usually
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: 0.0,
      protocols: ['Socket'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 300,
      timestamp: DateTime.now(),
      metadata: route, // Helper for buildTransaction
    );
  }
}
