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

/// Symbiosis Finance Provider
/// Extensive cross-chain support.
class SymbiosisProvider extends SwapProviderInterface {
  final Dio _dio;
  static const String _baseUrl = 'https://api.symbiosis.finance/v1';

  SymbiosisProvider({Dio? dio}) : _dio = dio ?? Dio();

  @override
  String get name => 'Symbiosis';

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
        ChainId.mantle,
        ChainId.scroll,
        ChainId.metis,
        ChainId.fantom,
        ChainId.aurora,
        ChainId.celo,
        ChainId.solana,
        ChainId.tron,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      final response =
          await _dio.get('https://api.symbiosis.finance/v1/tokens');
      final List<dynamic> data = response.data;

      final tokens = data.where((t) => t['chainId'] == chainId.id).map((t) {
        return Token(
          symbol: t['symbol'] ?? 'UNKNOWN',
          name: t['name'] ?? '',
          address: t['address'],
          decimals: int.tryParse(t['decimals']?.toString() ?? '18') ?? 18,
          chainId: chainId,
          logoUrl: t['logo'],
        );
      }).toList();

      return Result.success(tokens);
    } catch (e) {
      return Result.failure('Symbiosis tokens failed: $e');
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final response = await _dio.post(
        '$_baseUrl/swap/v1/quote',
        data: {
          'tokenIn': {
            'address': params.fromTokenAddress,
            'chainId': params.fromChain.id,
          },
          'tokenOut': {
            'address': params.toTokenAddress,
            'chainId': params.toChain.id,
          },
          'amountIn': params.amountInSmallestUnit.toString(),
          'from': params.userAddress,
          'to': params.userAddress,
          'slippage': params.slippage * 10, // bp
        },
      );

      final data = response.data;
      if (data['amountOut'] == null) {
        return Result.failure('Symbiosis quote error');
      }

      final quote = _parseQuote(data, params);
      return Result.success(quote);
    } catch (e) {
      return Result.failure('Symbiosis quote failed: $e');
    }
  }

  @override
  Future<Result<ChainTransaction>> buildTransactionV2({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    final raw = quote.metadata;
    final txData = raw['tx'];

    if (txData == null) {
      return Result.failure('Symbiosis transaction data missing from quote');
    }

    try {
      if (quote.params.fromChain == ChainId.solana) {
        return Result.success(SolanaTransaction(
          base64EncodedTransaction: txData['data'] ?? '',
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
          metadata: raw,
        ));
      }

      return Result.success(EvmTransaction(
        from: userAddress,
        to: txData['to'],
        data: txData['data'],
        value: BigInt.parse(txData['value']?.toString() ?? '0'),
        gasLimit: BigInt.parse(txData['gasLimit']?.toString() ?? '500000'),
        gasPrice: BigInt.parse(txData['gasPrice']?.toString() ?? '0'),
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
        metadata: raw,
      ));
    } catch (e) {
      return Result.failure('Failed to build Symbiosis transaction: $e');
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
    // We return success with 0 to trigger getApprovalMethod if needed.
    return Result.success(BigInt.zero);
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    // For Symbiosis, we typically get the router from the quote.
    // However, if we need it standalone, we use a fallback or fetch it.
    // Known Symbiosis MetaRouter addresses:
    switch (chainId) {
      case ChainId.ethereum:
        return Result.success('0xad7ab2eb3774889c9339796ff6f9fdfdd366016e');
      case ChainId.bsc:
        return Result.success('0xad7ab2eb3774889c9339796ff6f9fdfdd366016e');
      case ChainId.polygon:
        return Result.success('0xad7ab2eb3774889c9339796ff6f9fdfdd366016e');
      default:
        return Result.failure('Spender address not configured for $chainId');
    }
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    try {
      final response = await _dio.get('$_baseUrl/tx/${chainId.id}/$txHash');
      final data = response.data;

      final state = data['state']?.toString().toLowerCase();
      if (state == 'success') {
        return Result.success(SwapStatus.completed(txHash));
      }
      if (state == 'failed') {
        return Result.success(
            SwapStatus.failed(txHash, 'Symbiosis reported failure'));
      }

      return Result.success(SwapStatus.pending(txHash));
    } catch (e) {
      return Result.failure('Failed to check Symbiosis status: $e');
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final amountOut = Decimal.parse(data['amountOut']?.toString() ?? '0');
    final decimals =
        int.tryParse(data['tokenOut']?['decimals']?.toString() ?? '18') ?? 18;

    final divisor = Decimal.fromBigInt(BigInt.from(10).pow(decimals));
    final humanAmountOut = (amountOut / divisor).toDecimal();

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
        gasLimit: BigInt.parse(data['tx']?['gasLimit']?.toString() ?? '0'),
        gasPrice: BigInt.parse(data['tx']?['gasPrice']?.toString() ?? '0'),
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact:
          double.tryParse(data['priceImpact']?.toString() ?? '0.0') ?? 0.0,
      protocols: ['Symbiosis'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
