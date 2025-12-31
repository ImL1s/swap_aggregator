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

/// Li.Fi (Liquidity Fire) Provider
///
/// Cross-chain bridge and swap aggregator.
/// API Docs: https://docs.li.fi/
///
/// ## Example
/// ```dart
/// final lifi = LiFiProvider(apiKey: 'your-api-key');
/// final quote = await lifi.getQuote(params);
/// ```
class LiFiProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://li.quest/v1';

  final Dio _dio;
  final String? _apiKey;

  LiFiProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_apiKey != null) 'x-lifi-api-key': _apiKey,
    };
  }

  @override
  String get name => 'Li.Fi';

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
        ChainId.solana,
        ChainId.gnosis,
        ChainId.scroll,
        ChainId.blast,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/tokens',
        queryParameters: {'chains': chainId.id},
      );

      final data = response.data;
      final tokensMap = data['tokens']?[chainId.id.toString()];

      if (tokensMap is List) {
        final tokens = tokensMap
            .map((t) => Token(
                  symbol: t['symbol'] ?? '',
                  name: t['name'] ?? '',
                  address: t['address'] ?? '',
                  decimals: t['decimals'] ?? 18,
                  chainId: chainId,
                  logoUrl: t['logoURI'],
                ))
            .toList();
        return Result.success(tokens);
      }
      return Result.success([]);
    } catch (e) {
      return Result.failure('Failed to fetch tokens: $e');
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final queryParams = {
        'fromChain': params.fromChain.id,
        'toChain': params.toChain.id,
        'fromToken': params.fromTokenAddress,
        'toToken': params.toTokenAddress,
        'fromAmount': params.amountInSmallestUnit.toString(),
        'fromAddress': params.userAddress,
        'slippage': (params.slippage / 100).toString(), // 0.03 for 3%
      };

      final response = await _dio.get(
        '$_baseUrl/quote',
        queryParameters: queryParams,
      );

      final data = response.data;
      // Li.Fi quote response contains transaction data directly

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'Li.Fi quote failed: ${e.message}',
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
    final txData = quote.metadata['transactionRequest'];

    if (txData == null) {
      return Result.failure(
        'Missing transaction data in quote',
        code: 'MISSING_TX_DATA',
      );
    }

    try {
      final tx = EvmTransaction(
        from: txData['from'] ?? userAddress,
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
        metadata: quote.metadata,
      );

      return Result.success(tx);
    } catch (e) {
      return Result.failure('Failed to build transaction: $e');
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
    try {
      final response = await _dio.get(
        '$_baseUrl/status',
        queryParameters: {
          'txHash': txHash,
          'bridge': 'lifi', // Can be inferred or passed
        },
      );

      final data = response.data;
      final statusStr = data['status'] as String?;

      SwapStatusType status;
      if (statusStr == 'DONE') {
        status = SwapStatusType.completed;
      } else if (statusStr == 'FAILED') {
        status = SwapStatusType.failed;
      } else if (statusStr == 'PENDING') {
        status = SwapStatusType.processing;
      } else {
        status = SwapStatusType.pending;
      }

      return Result.success(
        SwapStatus(
          txHash: txHash,
          status: status,
          metadata: data,
          outputTxHash: data['receiving']?['txHash'],
        ),
      );
    } catch (e) {
      // Fallback for non-LiFi specific check or if endpoint differs
      return Result.failure(
        'Status check failed: $e',
        code: 'STATUS_ERROR',
      );
    }
  }

  @override
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    return Result.success(BigInt.zero); // Handled by caller or build step
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

    // Li.Fi usually doesn't provide spender without a quote.
    // However, for consistency, we try to return a result.
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
    // Diamon Proxy address is often used as spender
    // but it varies. Li.Fi provides it in quote.
    // For now, return failure to force quote-based approval check if possible
    // or provide the common Diamond Proxy if reachable.
    return Result.failure(
        'Li.Fi requires a quote to determine spender address');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final estimate = data['estimate'];
    final amountIn = BigInt.parse(estimate['fromAmount']?.toString() ?? '0');
    final amountOut = BigInt.parse(estimate['toAmount']?.toString() ?? '0');

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
      minimumOutputAmount: decimalOut *
          (Decimal.one -
              Decimal.parse('0.01') *
                  Decimal.parse(params.slippage.toString())),
      exchangeRate: exchangeRate,
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit:
            BigInt.parse(estimate['gasCosts']?[0]?['limit']?.toString() ?? '0'),
        gasPrice: BigInt.zero, // Usually included in limit or fees
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: double.tryParse(
              estimate['data']?['priceImpact']?.toString() ?? '0') ??
          0.0,
      protocols: ['Li.Fi'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 300,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
