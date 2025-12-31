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

/// CoW Protocol Provider
///
/// Intent-based batch auction protocol with MEV protection.
/// API Docs: https://docs.cow.fi/
class CowProvider extends SwapProviderInterface {
  final Dio _dio;

  CowProvider({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  @override
  String get name => 'CoW Protocol';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.gnosis,
        ChainId.arbitrum,
      ];

  @override
  bool get supportsCrossChain => false;

  String _getBaseUrl(ChainId chainId) {
    switch (chainId) {
      case ChainId.ethereum:
        return 'https://api.cow.fi/mainnet/api/v1';
      case ChainId.gnosis:
        return 'https://api.cow.fi/xdai/api/v1';
      case ChainId.arbitrum:
        return 'https://api.cow.fi/arbitrum_one/api/v1';
      default:
        throw Exception('CoW Protocol not supported on $chainId');
    }
  }

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final baseUrl = _getBaseUrl(params.fromChain);

      final body = {
        'sellToken': params.fromTokenAddress,
        'buyToken': params.toTokenAddress,
        'receiver': params.userAddress,
        'appData': '{}', // Standard app data
        'partiallyFillable': false,
        'sellAmountBeforeFee': params.amountInSmallestUnit.toString(),
        'kind': 'sell',
      };

      final response = await _dio.post(
        '$baseUrl/quote',
        data: body,
      );

      final data = response.data;
      if (data == null || data['quote'] == null) {
        return Result.failure('No quote from CoW Protocol');
      }

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'CoW quote failed: ${e.message}',
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
    final quoteData = quote.metadata['quote'];
    if (quoteData == null) {
      return Result.failure('Missing quote data in Cow metadata');
    }

    try {
      return Result.success(
        EvmTransaction(
          from: userAddress,
          to: '0x9008D19f58AAbD9eD0D60971565AA8510560ab41', // GPv2Settlement
          data: 'intent:cow_protocol', // Prefix for intent-based swaps
          value: BigInt.zero,
          gasLimit: BigInt.zero,
          gasPrice: BigInt.zero,
          chainId: quote.params.fromChain,
          summary: TransactionSummary(
            action: 'Sign Order',
            fromAsset: quote.params.fromToken,
            toAsset: quote.params.toToken,
            inputAmount: quote.inputAmount,
            expectedOutput: quote.outputAmount,
            protocol: name,
          ),
          metadata: {
            'order': quoteData,
            'id': quote.metadata['id'],
            'isIntent': true,
          },
        ),
      );
    } catch (e) {
      return Result.failure('Failed to build CoW transaction data: $e');
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
    // CoW status tracked by order UID, not txHash
    try {
      final baseUrl = _getBaseUrl(chainId);
      final response = await _dio.get('$baseUrl/orders/$txHash');

      final data = response.data;
      final statusStr = data['status'] ?? 'pending';

      SwapStatusType status;
      if (statusStr == 'fulfilled') {
        status = SwapStatusType.completed;
      } else if (statusStr == 'cancelled' || statusStr == 'expired') {
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
    // CoW Protocol Vault Relayer
    return Result.success('0xC92E8bdf79f0507f65a392b0ab4667716BFE0110');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final quote = data['quote'];
    final sellAmount = BigInt.parse(quote['sellAmount']?.toString() ?? '0');
    final buyAmount = BigInt.parse(quote['buyAmount']?.toString() ?? '0');
    final feeAmount = BigInt.parse(quote['feeAmount']?.toString() ?? '0');

    // Total sell including fee
    final totalSell = sellAmount + feeAmount;

    final decimalIn = (Decimal.fromBigInt(totalSell) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.fromTokenDecimals)))
        .toDecimal();

    final decimalOut = (Decimal.fromBigInt(buyAmount) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.toTokenDecimals)))
        .toDecimal();

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: decimalIn,
      outputAmount: decimalOut,
      minimumOutputAmount: decimalOut, // Protocol handles slippage
      exchangeRate: decimalIn > Decimal.zero
          ? (decimalOut / decimalIn).toDecimal()
          : Decimal.zero,
      routes: [],
      gasEstimate:
          GasEstimate.zero(nativeSymbol: params.fromChain.nativeSymbol),
      priceImpact: 0.0,
      protocols: ['CoW Protocol'],
      validUntil: int.tryParse(quote['validTo']?.toString() ?? '0') ?? 0,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
