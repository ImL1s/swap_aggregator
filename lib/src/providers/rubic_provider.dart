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

/// Rubic Provider
///
/// Cross-chain aggregator supporting 360+ DEXs and bridges.
/// API Docs: https://docs.rubic.exchange/
class RubicProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api-v2.rubic.exchange/api';

  final Dio _dio;
  final String _referrer;

  RubicProvider({Dio? dio, String referrer = 'rubic.exchange'})
      : _dio = dio ?? Dio(),
        _referrer = referrer {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  @override
  String get name => 'Rubic';

  @override
  List<ChainId> get supportedChains => ChainId.values;

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // Rubic has a large token list, but fetching all is heavy.
    // Use external list or specific search if needed.
    return Result.success([]);
  }

  String _mapChainToRubic(ChainId chainId) {
    switch (chainId) {
      case ChainId.ethereum:
        return 'ETH';
      case ChainId.bsc:
        return 'BSC';
      case ChainId.polygon:
        return 'POLYGON';
      case ChainId.arbitrum:
        return 'ARBITRUM';
      case ChainId.optimism:
        return 'OPTIMISM';
      case ChainId.avalanche:
        return 'AVAX';
      case ChainId.fantom:
        return 'FANTOM';
      case ChainId.base:
        return 'BASE';
      case ChainId.linea:
        return 'LINEA';
      case ChainId.zksync:
        return 'ZKSYNC';
      case ChainId.scroll:
        return 'SCROLL';
      case ChainId.mantle:
        return 'MANTLE';
      case ChainId.gnosis:
        return 'GNOSIS';
      case ChainId.blast:
        return 'BLAST';
      case ChainId.solana:
      case ChainId.legacy_solana:
        return 'SOLANA';
      case ChainId.tron:
        return 'TRON';
      case ChainId.ton:
        return 'TON';
      case ChainId.bitcoin:
        return 'BITCOIN';
      case ChainId.near:
        return 'NEAR';
      case ChainId.aurora:
        return 'AURORA';
      case ChainId.metis:
        return 'METIS';
      case ChainId.moonbeam:
        return 'MOONBEAM';
      case ChainId.moonriver:
        return 'MOONRIVER';
      case ChainId.celo:
        return 'CELO';
      case ChainId.cronos:
        return 'CRONOS';
      default:
        return chainId.name.toUpperCase();
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final body = {
        'srcTokenAddress': params.fromTokenAddress,
        'srcTokenBlockchain': _mapChainToRubic(params.fromChain),
        'srcTokenAmount': params.amountInSmallestUnit.toString(),
        'dstTokenAddress': params.toTokenAddress,
        'dstTokenBlockchain': _mapChainToRubic(params.toChain),
        'referrer': _referrer,
        'fromAddress': params.userAddress,
        'receiver': params.userAddress,
        'slippage':
            params.slippage / 100, // Rubic uses decimal (e.g. 0.01 for 1%)
      };

      // Use quoteBest for optimal route
      final response = await _dio.post(
        '$_baseUrl/routes/quoteBest',
        data: body,
      );

      final data = response.data;
      if (data == null || data['estimate'] == null) {
        return Result.failure('No quote found on Rubic');
      }

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'Rubic quote failed: ${e.message}',
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
    final txData = quote.metadata['transaction'];
    if (txData == null) {
      return Result.failure('Transaction data missing in Rubic quote');
    }

    try {
      if (quote.params.fromChain == ChainId.solana ||
          quote.params.fromChain == ChainId.legacy_solana) {
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
          metadata: quote.metadata,
        ));
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
          metadata: quote.metadata,
        ),
      );
    } catch (e) {
      return Result.failure('Failed to parse Rubic transaction: $e');
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
    // Rubic tracks status via /trades/{id}
    // We need the swap id from metadata
    return Result.failure('Status check requires Rubic Trade ID',
        code: 'NOT_SUPPORTED');
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
    // Rubic spender varies by provider, best to get from quote metadata
    return Result.failure(
        'Rubic spender address is route-dependent. Check quote metadata.');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final estimate = data['estimate'];
    final amountIn = params.amountInSmallestUnit;
    final amountOut =
        BigInt.parse(estimate['destinationWeiAmount']?.toString() ?? '0');

    final decimalIn = (Decimal.fromBigInt(amountIn) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.fromTokenDecimals)))
        .toDecimal();

    final decimalOut = (Decimal.fromBigInt(amountOut) /
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
      minimumOutputAmount: (Decimal.fromBigInt(BigInt.parse(
                  estimate['destinationWeiMinAmount']?.toString() ?? '0')) /
              Decimal.fromBigInt(BigInt.from(10).pow(params.toTokenDecimals)))
          .toDecimal(),
      exchangeRate: exchangeRate,
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit: BigInt.zero, // Usually included in transaction data
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: (estimate['priceImpact'] ?? 0.0) / 100,
      protocols: [data['providerType'] ?? 'Rubic'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 300,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
