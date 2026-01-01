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
import '../utils/unit_utils.dart';

/// Across Protocol Provider
/// Cross-chain bridge and aggregator.
class AcrossProvider extends SwapProviderInterface {
  final Dio _dio;
  static const String _baseUrl = 'https://app.across.to/api';

  AcrossProvider({Dio? dio}) : _dio = dio ?? Dio();

  @override
  String get name => 'Across';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.polygon,
        ChainId.base,
        ChainId.zksync,
        ChainId.linea,
        ChainId.blast,
        ChainId.scroll,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    return Result.failure(
        'Token list not directly supported by Across provider');
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/suggested-fees',
        queryParameters: {
          'inputToken': params.fromTokenAddress,
          'outputToken': params.toTokenAddress,
          'originChainId': params.fromChain.id,
          'destinationChainId': params.toChain.id,
          'amount': params.amountInSmallestUnit.toString(),
        },
      );

      final data = response.data;
      if (data['relayFeePct'] == null) {
        return Result.failure('Across quote error: no relay fee info');
      }

      final quote = _parseQuote(data, params);
      return Result.success(quote);
    } catch (e) {
      return Result.failure('Across quote failed: $e');
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
        '$_baseUrl/swap/approval',
        queryParameters: {
          'originChainId': quote.params.fromChain.id,
          'destinationChainId': quote.params.toChain.id,
          'inputToken': quote.params.fromTokenAddress,
          'outputToken': quote.params.toTokenAddress,
          'amount': quote.params.amountInSmallestUnit.toString(),
          'depositor': userAddress,
          'recipient': recipientAddress ?? userAddress,
          'tradeType': 'exactInput',
        },
      );

      final data = response.data;
      if (data['swapTransaction'] == null) {
        return Result.failure(
            'Across transaction data missing from approval response');
      }

      final tx = data['swapTransaction'];
      return Result.success(EvmTransaction(
        from: userAddress,
        to: tx['to'],
        data: tx['data'],
        value: BigInt.parse(tx['value']?.toString() ?? '0'),
        gasLimit: BigInt.parse(tx['gasLimit']?.toString() ?? '300000'),
        gasPrice: BigInt.parse(tx['gasPrice']?.toString() ?? '0'),
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
      return Result.failure('Across transaction build failed: $e');
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
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/swap/approval',
        queryParameters: {
          'originChainId': chainId.id,
          'inputToken': tokenAddress,
          'depositor': ownerAddress,
          // Need these to satisfy the endpoint, use dummies if checking general allowance
          'destinationChainId': chainId.id,
          'outputToken': tokenAddress,
          'amount': '0',
          'tradeType': 'exactInput',
        },
      );
      final allowance = BigInt.parse(
          response.data['allowance']?['currentAllowance']?.toString() ?? '0');
      return Result.success(allowance);
    } catch (e) {
      return Result.failure('Across allowance check failed: $e');
    }
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

    try {
      final response = await _dio.get(
        '$_baseUrl/swap/approval',
        queryParameters: {
          'originChainId': chainId.id,
          'inputToken': tokenAddress,
          'destinationChainId': chainId.id,
          'outputToken': tokenAddress,
          'amount': amount.toString(),
          'depositor': ownerAddress,
          'tradeType': 'exactInput',
        },
      );

      final data = response.data;
      final approvalTx = data['approvalTransaction'];
      if (approvalTx == null) {
        return Result.failure('Across approval transaction not provided');
      }

      final tx = EvmTransaction(
        from: ownerAddress,
        to: approvalTx['to'],
        data: approvalTx['data'],
        value: BigInt.zero,
        gasLimit: BigInt.parse('100000'),
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
        spenderAddress: approvalTx['to'],
        amount: amount,
      ));
    } catch (e) {
      return Result.failure('Across approval method failed: $e');
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
    // Spender depends on the chain. We can extract it from an approval Tx
    // or return a common one if known. For Across, SpokePool is the spender.
    return Result.failure(
        'Across spender varies by chain. Use getApprovalTransaction.');
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/deposit/status',
        queryParameters: {'depositTxHash': txHash},
      );
      final data = response.data;

      final status = data['status']?.toString().toLowerCase();
      if (status == 'filled') {
        return Result.success(SwapStatus.completed(txHash));
      }
      if (status == 'failed' || status == 'expired') {
        return Result.success(
            SwapStatus.failed(txHash, 'Across reported $status'));
      }

      return Result.success(SwapStatus.pending(txHash));
    } catch (e) {
      return Result.failure('Across status check failed: $e');
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    // Across returns quote with fees subtracted
    final depositValue = BigInt.parse(
        data['depositValue'] ?? params.amountInSmallestUnit.toString());
    final totalRelayFee = BigInt.parse(data['totalRelayFee']?['total'] ?? '0');
    final outAmountSmallest = depositValue - totalRelayFee;

    final srcAmount = params.amountInSmallestUnit;
    final destAmount = outAmountSmallest;
    final minDestAmount =
        outAmountSmallest; // Across has specific slippage in tx build

    final inputAmount =
        UnitUtils.fromTokenUnit(srcAmount, params.fromTokenDecimals);
    final outputAmount =
        UnitUtils.fromTokenUnit(destAmount, params.toTokenDecimals);
    final minOutput =
        UnitUtils.fromTokenUnit(minDestAmount, params.toTokenDecimals);

    final exchangeRate =
        inputAmount > Decimal.zero ? outputAmount / inputAmount : Decimal.zero;

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      minimumOutputAmount: minOutput,
      exchangeRate: Decimal.parse(exchangeRate.toString()),
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit: BigInt.from(250000), // Slightly more conservative default
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: 0.0,
      protocols: ['Across'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 300,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
