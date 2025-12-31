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

/// Squid Provider (Axelar)
///
/// Cross-chain router using Axelar Network.
/// API Docs: https://docs.squidrouter.com/
class SquidProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://v2.api.squidrouter.com/v2';

  final Dio _dio;
  final String? _integratorId;

  SquidProvider({Dio? dio, String? integratorId})
      : _dio = dio ?? Dio(),
        _integratorId = integratorId {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_integratorId != null) 'x-integrator-id': _integratorId,
    };
  }

  @override
  String get name => 'Squid';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.bsc,
        ChainId.polygon,
        ChainId.avalanche,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.base,
        ChainId.linea,
        ChainId.fantom,
        ChainId.moonbeam,
        ChainId.celo,
        ChainId.gnosis,
        ChainId.mantle,
        ChainId.scroll,
        ChainId.blast,
        ChainId.osmosis,
        ChainId.cosmos,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // Squid has a /v2/tokens endpoint
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final queryParams = {
        'fromChain': params.fromChain.id.toString(),
        'toChain': params.toChain.id.toString(),
        'fromToken': params.fromTokenAddress,
        'toToken': params.toTokenAddress,
        'fromAmount': params.amountInSmallestUnit.toString(),
        'fromAddress': params.userAddress,
        'toAddress': params.userAddress,
        'slippage': params.slippage.toString(),
        'quoteOnly': false, // Set to false to get full route data for build-tx
      };

      final response = await _dio.get(
        '$_baseUrl/route',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data == null || data['route'] == null) {
        return Result.failure('No route found on Squid');
      }

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'Squid quote failed: ${e.message}',
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
    final txData = quote.metadata['route']?['transactionRequest'];
    if (txData == null) {
      return Result.failure('Transaction data missing in Squid quote');
    }

    try {
      if (quote.params.fromChain == ChainId.cosmos ||
          quote.params.fromChain == ChainId.osmosis) {
        final messages = (txData['messages'] as List?)
                ?.map((m) => CosmosMessage(
                      typeUrl: m['typeUrl']?.toString() ?? '',
                      value: Map<String, dynamic>.from(m['value'] ?? {}),
                    ))
                .toList() ??
            [];

        final feeData = txData['fee'];
        final fee = feeData != null
            ? CosmosFee(
                amount: (feeData['amount'] as List?)
                        ?.map((c) => CosmosCoin(
                              denom: c['denom']?.toString() ?? '',
                              amount:
                                  BigInt.parse(c['amount']?.toString() ?? '0'),
                            ))
                        .toList() ??
                    [],
                gasLimit:
                    BigInt.parse(feeData['gasLimit']?.toString() ?? '200000'),
                granter: feeData['granter']?.toString(),
                payer: feeData['payer']?.toString(),
              )
            : CosmosFee(amount: [], gasLimit: BigInt.from(200000));

        return Result.success(CosmosTransaction(
          messages: messages,
          fee: fee,
          memo: txData['memo']?.toString() ?? 'Squid Router',
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
          metadata: quote.metadata,
        ));
      }

      return Result.success(
        EvmTransaction(
          from: txData['from'] ?? userAddress,
          to: txData['to'],
          data: txData['data'],
          value: BigInt.parse(txData['value']?.toString() ?? '0'),
          gasLimit: BigInt.parse(txData['gasLimit']?.toString() ?? '1000000'),
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
          metadata: quote.metadata,
        ),
      );
    } catch (e) {
      return Result.failure('Failed to parse Squid transaction: $e');
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

    final tx = (result as Success<ChainTransaction>).value;
    if (tx is EvmTransaction) {
      return Result.success(SwapTransaction(
        from: tx.from,
        to: tx.to,
        data: tx.data,
        value: tx.value,
        gasLimit: tx.gasLimit,
        gasPrice: tx.gasPrice,
        chainId: tx.chainId,
        metadata: tx.metadata,
      ));
    }
    return Result.failure(
        'Only EVM transactions supported in V1 buildTransaction');
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/status',
        queryParameters: {'transactionId': txHash},
      );

      final data = response.data;
      final statusStr = data['squidTransactionStatus'] ?? 'pending';

      SwapStatusType status;
      if (statusStr == 'success') {
        status = SwapStatusType.completed;
      } else if (statusStr == 'failed') {
        status = SwapStatusType.failed;
      } else {
        status = SwapStatusType.processing;
      }

      return Result.success(
        SwapStatus(
          txHash: txHash,
          status: status,
          metadata: data,
        ),
      );
    } catch (e) {
      return Result.failure('Status check failed: $e');
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
    // Squid Multi-chain router address
    // Can be fetched from /v2/chains or hardcoded
    return Result.failure('Route dependent spender. See quote metadata.');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final route = data['route'];
    final estimate = route['estimate'];

    final amountIn = params.amountInSmallestUnit;
    final amountOut = BigInt.parse(estimate['toAmount']?.toString() ?? '0');

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
      minimumOutputAmount: (Decimal.fromBigInt(
                  BigInt.parse(estimate['toAmountMin']?.toString() ?? '0')) /
              Decimal.fromBigInt(BigInt.from(10).pow(params.toTokenDecimals)))
          .toDecimal(),
      exchangeRate: decimalIn > Decimal.zero
          ? (decimalOut / decimalIn).toDecimal()
          : Decimal.zero,
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit: BigInt.zero,
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: double.tryParse(
              estimate['aggregatePriceImpact']?.toString() ?? '0') ??
          0.0,
      protocols: ['Squid'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 300,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
