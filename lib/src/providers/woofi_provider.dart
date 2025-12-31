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

/// WOOFi Provider
/// Competitive rates and low fees.
class WOOFiProvider extends SwapProviderInterface {
  final Dio _dio;
  static const String _baseUrl = 'https://fi-api.woo.org/v1';

  WOOFiProvider({Dio? dio}) : _dio = dio ?? Dio();

  @override
  String get name => 'WOOFi';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.bsc,
        ChainId.polygon,
        ChainId.avalanche,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.base,
        ChainId.zksync,
        ChainId.linea,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      final response =
          await _dio.get('https://api.orderly.org/v1/public/token');
      final List<dynamic> data = response.data['data']['rows'];

      final tokens = data.map((t) {
        return Token(
          symbol: t['token'] ?? 'UNKNOWN',
          name: t['token'] ?? '',
          address: '', // Orderly is symbol-based primarily
          decimals: 18,
          chainId: chainId,
        );
      }).toList();

      return Result.success(tokens);
    } catch (e) {
      return Result.failure('WOOFi tokens failed: $e');
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/quote',
        queryParameters: {
          'fromChainId': params.fromChain.id,
          'toChainId': params.toChain.id,
          'fromTokenAddress': params.fromTokenAddress,
          'toTokenAddress': params.toTokenAddress,
          'amount': params.amountInSmallestUnit.toString(),
          'slippage': params.slippage.toString(),
        },
      );

      final data = response.data;
      if (data['data'] == null || data['data']['toAmount'] == null) {
        return Result.failure('WOOFi quote error');
      }

      final quote = _parseQuote(data, params);
      return Result.success(quote);
    } catch (e) {
      return Result.failure('WOOFi quote failed: $e');
    }
  }

  @override
  Future<Result<ChainTransaction>> buildTransactionV2({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/buildTransaction',
        queryParameters: {
          'fromChainId': quote.params.fromChain.id,
          'toChainId': quote.params.toChain.id,
          'fromTokenAddress': quote.params.fromTokenAddress,
          'toTokenAddress': quote.params.toTokenAddress,
          'amount': quote.params.amountInSmallestUnit.toString(),
          'slippage': quote.params.slippage.toString(),
          'fromAddress': userAddress,
          'toAddress': recipientAddress ?? userAddress,
        },
      );

      final data = response.data['data'];
      return Result.success(EvmTransaction(
        from: userAddress,
        to: data['to'],
        data: data['data'],
        value: BigInt.parse(data['value']?.toString() ?? '0'),
        gasLimit: BigInt.parse(data['gasLimit']?.toString() ?? '500000'),
        gasPrice: BigInt.parse(data['gasPrice']?.toString() ?? '0'),
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
        metadata: data,
      ));
    } catch (e) {
      return Result.failure('WOOFi transaction build failed: $e');
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

    final spenderRes = await getSpenderAddress(chainId);
    if (spenderRes.isFailure) return Result.failure(spenderRes.errorOrNull!);
    final spender = spenderRes.valueOrNull!;

    final tx = EvmTransaction(
      from: ownerAddress,
      to: tokenAddress,
      data: '0x095ea7b3'
          '${spender.replaceAll('0x', '').padLeft(64, '0')}'
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
      spenderAddress: spender,
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
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    // This would typically involve a contract call.
    // Return success 0 to trigger getApprovalMethod for tokens.
    return Result.success(BigInt.zero);
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    // WOOFi WooRouterV2 address is 0x4c4AF8DBc524681930a27b2F1Af5bcC8062E6fB7 on most EVM chains
    if (chainId == ChainId.zksync) {
      return Result.success('0x09873bfECA34F1Acd0a7e55cDA591f05d8a75369');
    }
    return Result.success('0x4c4AF8DBc524681930a27b2F1Af5bcC8062E6fB7');
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.failure('Status tracking not implemented for WOOFi');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final quoteData = data['data'];
    final toAmount = Decimal.parse(quoteData['toAmount'].toString());
    // decmials for toToken
    final decimals =
        18; // WOOFi API should return decimals, but let's assume 18 for now if missing

    final divisor = Decimal.fromBigInt(BigInt.from(10).pow(decimals));
    final humanAmountOut = (toAmount / divisor).toDecimal();

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: params.amount,
      outputAmount: humanAmountOut,
      minimumOutputAmount: (humanAmountOut *
          Decimal.parse((1 - params.slippage / 100).toString())),
      exchangeRate: (humanAmountOut / params.amount).toDecimal(),
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit: BigInt.parse('300000'), // Approx
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: 0.0,
      protocols: ['WOOFi sPMM'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
