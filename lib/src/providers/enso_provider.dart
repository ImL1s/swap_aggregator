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

/// Enso Provider
///
/// Meta-aggregator for DeFi shortcuts and routing.
/// API Docs: https://docs.enso.finance/
class EnsoProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.enso.finance/v1';

  final Dio _dio;
  final String? _apiKey;

  EnsoProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_apiKey != null) 'Authorization': 'Bearer $_apiKey',
    };
  }

  @override
  String get name => 'Enso';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.optimism,
        ChainId.bsc,
        ChainId.polygon,
        ChainId.base,
        ChainId.arbitrum,
        ChainId.avalanche,
        ChainId.linea,
      ];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // Enso has a /tokens endpoint
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final queryParams = {
        'chainId': params.fromChain.id,
        'fromAddress': params.userAddress,
        'tokenIn': params.fromTokenAddress,
        'amountIn': params.amountInSmallestUnit.toString(),
        'tokenOut': params.toTokenAddress,
        'slippage': (params.slippage * 100).toInt(), // Enso uses bps (100 = 1%)
      };

      final response = await _dio.get(
        '$_baseUrl/shortcuts/route',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data == null || data['amountOut'] == null) {
        return Result.failure('No quote from Enso');
      }

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'Enso quote failed: ${e.message}',
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
    final txData = quote.metadata['tx'];
    if (txData == null) {
      return Result.failure('Transaction data missing in Enso quote');
    }

    try {
      return Result.success(
        EvmTransaction(
          from: userAddress,
          to: txData['to'],
          data: txData['data'],
          value: BigInt.parse(txData['value']?.toString() ?? '0'),
          gasLimit: BigInt.parse(txData['gas']?.toString() ?? '500000'),
          gasPrice: BigInt.zero,
          chainId: quote.params.fromChain,
          summary: TransactionSummary(
            action: 'Swap',
            fromAsset: quote.params.fromToken,
            toAsset: quote.params.toToken,
            inputAmount: quote.inputAmount,
            expectedOutput: quote.outputAmount,
            protocol: name,
          ),
          metadata: quote.metadata,
        ),
      );
    } catch (e) {
      return Result.failure('Failed to parse Enso transaction: $e');
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
    return Result.failure('Not supported', code: 'NOT_SUPPORTED');
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
    // Enso router address usually returned in quote
    // Common one: 0x2e84897Ef6017366B570a2AcE1D03C5331eF1735 (Example)
    return Result.success('0x2e84897Ef6017366B570a2AcE1D03C5331eF1735');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final amountIn = params.amountInSmallestUnit;
    final amountOut = BigInt.parse(data['amountOut']?.toString() ?? '0');

    final decimalIn = (Decimal.fromBigInt(amountIn) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.fromTokenDecimals)))
        .toDecimal();

    final decimalOut = (Decimal.fromBigInt(amountOut) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.toTokenDecimals)))
        .toDecimal();

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: decimalIn,
      outputAmount: decimalOut,
      minimumOutputAmount: decimalOut *
          (Decimal.one - Decimal.parse('0.01')), // Default 1% slippage
      exchangeRate: decimalIn > Decimal.zero
          ? (decimalOut / decimalIn).toDecimal()
          : Decimal.zero,
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit: BigInt.parse(data['gas']?.toString() ?? '0'),
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: 0.0,
      protocols: ['Enso'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 300,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
