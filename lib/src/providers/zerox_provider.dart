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

/// 0x API v2 Provider (Allowance Holder)
///
/// Requires an API key for production use.
/// Get your API key at https://dashboard.0x.org/
///
/// API Documentation: https://0x.org/docs/api
///
/// ## Example
/// ```dart
/// final zerox = ZeroXProvider(apiKey: 'your-api-key');
/// final quote = await zerox.getQuote(params);
/// ```
class ZeroXProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.0x.org/swap/allowance-holder';

  final Dio _dio;
  final String? _apiKey;

  ZeroXProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_apiKey != null) '0x-api-key': _apiKey,
      '0x-version': 'v2',
    };
  }

  @override
  String get name => '0x';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.polygon,
        ChainId.bsc,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.avalanche,
        ChainId.fantom,
        ChainId.base,
      ];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // 0x doesn't provide a token list endpoint
    // Return empty list - tokens should be provided by the application
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      // v2 API uses unified endpoint with chainId parameter
      final queryParams = {
        'chainId': params.fromChain.id.toString(),
        'sellToken': params.fromTokenAddress,
        'buyToken': params.toTokenAddress,
        'sellAmount': params.amountInSmallestUnit.toString(),
        'taker': params.userAddress,
        'slippageBps': (params.slippage * 100).toInt().toString(),
      };

      final response = await _dio.get(
        '$_baseUrl/quote',
        queryParameters: queryParams,
      );

      final data = response.data;
      final quote = _parseQuote(data, params);
      return Result.success(quote);
    } on DioException catch (e) {
      return Result.failure(
        'Failed to get quote: ${e.message}',
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
    final txData = quote.metadata['transaction'] ?? quote.metadata;

    try {
      final tx = EvmTransaction(
        from: txData['from'] ?? userAddress,
        to: txData['to'] ?? '',
        data: txData['data'] ?? '',
        value: BigInt.parse(txData['value']?.toString() ?? '0'),
        gasLimit: BigInt.parse(txData['gas']?.toString() ?? '500000'),
        gasPrice: BigInt.parse(txData['gasPrice']?.toString() ?? '0'),
        chainId: quote.params.fromChain,
        summary: TransactionSummary(
          action: 'Swap',
          fromAsset: quote.params.fromToken,
          toAsset: quote.params.toToken,
          inputAmount: quote.inputAmount,
          expectedOutput: quote.outputAmount,
          protocol: name,
        ),
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
      metadata: {'summary': evmTx.summary.toString()},
    ));
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.failure(
      'Status check not supported for 0x. Monitor chain for txHash: $txHash',
      code: 'NOT_SUPPORTED',
    );
  }

  @override
  Future<Result<ApprovalMethod>> getApprovalMethod({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
    required BigInt amount,
  }) async {
    try {
      // 0x v2 doesn't have a direct allowance endpoint, but /price response includes allowance issues.
      // We can call /price with a small amount to check if an allowance is needed.
      final response = await _dio.get(
        '$_baseUrl/price',
        queryParameters: {
          'chainId': chainId.id.toString(),
          'sellToken': tokenAddress,
          'buyToken': '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', // ETH
          'sellAmount': amount.toString(),
          'taker': ownerAddress,
        },
      );

      final data = response.data;
      final allowanceIssue = data['issues']?['allowance'];

      if (allowanceIssue == null) {
        return Result.success(
            NoApprovalNeeded(reason: 'No allowance issue reported by 0x API'));
      }

      final spender = allowanceIssue['spender']?.toString();
      if (spender == null) {
        return Result.failure('Missing spender in allowance issue');
      }

      // Construct manual ERC20 approval
      final spenderPadded = spender.replaceFirst('0x', '').padLeft(64, '0');
      final amountPadded = amount.toRadixString(16).padLeft(64, '0');
      final txData = '0x095ea7b3$spenderPadded$amountPadded';

      final tx = EvmTransaction(
        from: ownerAddress,
        to: tokenAddress,
        data: txData,
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
        spenderAddress: spender,
        amount: amount,
      ));
    } catch (e) {
      // If /price fails, fallback to standard spender address
      final spenderResult = await getSpenderAddress(chainId);
      if (spenderResult.isFailure) {
        return Result.failure(
            'Failed to get spender for fallback: ${spenderResult.errorOrNull}');
      }

      final spender = spenderResult.valueOrNull!;
      final spenderPadded = spender.replaceFirst('0x', '').padLeft(64, '0');
      final amountPadded = amount.toRadixString(16).padLeft(64, '0');
      final txData = '0x095ea7b3$spenderPadded$amountPadded';

      final tx = EvmTransaction(
        from: ownerAddress,
        to: tokenAddress,
        data: txData,
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
        spenderAddress: spender,
        amount: amount,
      ));
    }
  }

  @override
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    try {
      final response = await _dio.get(
        '$_baseUrl/price',
        queryParameters: {
          'chainId': chainId.id.toString(),
          'sellToken': tokenAddress,
          'buyToken': '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', // ETH
          'sellAmount': '1000000', // Arbitrary amount
          'taker': ownerAddress,
        },
      );

      final allowanceIssue = response.data['issues']?['allowance'];
      if (allowanceIssue == null) {
        // No issue means allowance is sufficient for the arbitrary amount
        // But we don't know the exact allowance.
        // Returning a large number or 0 is problematic.
        // 0x API v2 doesn't return the "actual" allowance if there's no issue.
        return Result.success(BigInt.from(1000000));
      }

      final actual = BigInt.parse(allowanceIssue['actual']?.toString() ?? '0');
      return Result.success(actual);
    } catch (e) {
      return Result.failure('Failed to check allowance via 0x API');
    }
  }

  @override
  @deprecated
  Future<Result<ApprovalTransaction>> getApprovalTransaction({
    required ChainId chainId,
    required String tokenAddress,
    BigInt? amount,
  }) async {
    final spenderResult = await getSpenderAddress(chainId);
    if (spenderResult.isFailure) {
      return Result.failure(spenderResult.errorOrNull!);
    }

    final spender = spenderResult.valueOrNull!;
    final approvalAmount = amount ??
        BigInt.parse(
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
          radix: 16,
        );

    final spenderPadded = spender.replaceFirst('0x', '').padLeft(64, '0');
    final amountPadded = approvalAmount.toRadixString(16).padLeft(64, '0');
    final txData = '0x095ea7b3$spenderPadded$amountPadded';

    final tx = SwapTransaction(
      from: '',
      to: tokenAddress,
      data: txData,
      value: BigInt.zero,
      gasLimit: BigInt.from(60000),
      gasPrice: BigInt.zero,
      chainId: chainId,
      metadata: {},
    );

    return Result.success(
      ApprovalTransaction(
        chainId: chainId,
        tokenAddress: tokenAddress,
        spenderAddress: spender,
        amount: approvalAmount,
        transaction: tx,
      ),
    );
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    // 0x v2 Allowance Holder contract address (same across all chains)
    return Result.success('0x0000000000001fF3684f28c67538d4D072C22734');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final srcAmount = Decimal.fromBigInt(
      BigInt.parse(data['sellAmount']?.toString() ?? '0'),
    );
    final destAmount = Decimal.fromBigInt(
      BigInt.parse(data['buyAmount']?.toString() ?? '0'),
    );

    final srcDivisor = Decimal.fromBigInt(
      BigInt.from(10).pow(params.fromTokenDecimals),
    );
    final destDivisor = Decimal.fromBigInt(
      BigInt.from(10).pow(params.toTokenDecimals),
    );

    final inputAmount = (srcAmount / srcDivisor).toDecimal();
    final outputAmount = (destAmount / destDivisor).toDecimal();
    final minOutput = outputAmount *
        (Decimal.one -
            Decimal.parse('0.01') * Decimal.parse(params.slippage.toString()));

    final exchangeRate =
        inputAmount > Decimal.zero ? outputAmount / inputAmount : Decimal.zero;

    final gasLimit = BigInt.parse(data['gas']?.toString() ?? '200000');
    final gasPrice = BigInt.parse(data['gasPrice']?.toString() ?? '0');

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      minimumOutputAmount: minOutput,
      exchangeRate: Decimal.parse(exchangeRate.toString()),
      routes: _parseRoutes(data['sources']),
      gasEstimate: GasEstimate.fromWei(
        gasLimit: gasLimit,
        gasPrice: gasPrice,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact:
          double.tryParse(data['estimatedPriceImpact']?.toString() ?? '0') ??
              0.0,
      protocols: _extractProtocols(data['sources']),
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }

  List<SwapRoute> _parseRoutes(dynamic sources) {
    if (sources == null || sources is! List) return [];

    return sources
        .where(
          (s) =>
              s is Map &&
              double.tryParse(s['proportion']?.toString() ?? '0') != 0,
        )
        .map<SwapRoute>(
          (source) => SwapRoute(
            protocol: source['name']?.toString() ?? '',
            portion:
                double.parse(source['proportion']?.toString() ?? '0') * 100,
            steps: [],
          ),
        )
        .toList();
  }

  List<String> _extractProtocols(dynamic sources) {
    if (sources == null || sources is! List) return [];

    return sources
        .where(
          (s) =>
              s is Map &&
              double.tryParse(s['proportion']?.toString() ?? '0') != 0,
        )
        .map<String>((s) => s['name']?.toString() ?? '')
        .toList();
  }
}
