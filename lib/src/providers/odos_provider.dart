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

/// Odos Provider (Smart Order Routing)
///
/// Smart Order Routing (SOR) provider for optimal swap paths.
/// API Docs: https://docs.odos.xyz/
class OdosProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.odos.xyz';

  final Dio _dio;
  final String? _referralCode;

  OdosProvider({Dio? dio, String? referralCode})
      : _dio = dio ?? Dio(),
        _referralCode = referralCode {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  @override
  String get name => 'Odos';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.polygon,
        ChainId.avalanche,
        ChainId.bsc,
        ChainId.base,
        ChainId.fantom,
        ChainId.zksync,
        ChainId.linea,
        ChainId.scroll,
        ChainId.mantle,
      ];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // Odos doesn't provide a lightweight public token list endpoint suitable for this flow.
    // Recommended to use external token lists.
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final body = {
        'chainId': params.fromChain.id,
        'inputTokens': [
          {
            'tokenAddress': params.fromTokenAddress,
            'amount': params.amountInSmallestUnit.toString(),
          }
        ],
        'outputTokens': [
          {
            'tokenAddress': params.toTokenAddress,
            'proportion': 1,
          }
        ],
        'userAddr': params.userAddress,
        'slippageLimitPercent':
            params.slippage, // Direct percent, e.g. 0.3 for 0.3%
        'referralCode': int.tryParse(_referralCode ?? '0') ?? 0,
        'compact': true,
      };

      final response = await _dio.post(
        '$_baseUrl/sor/quote/v2',
        data: body,
      );

      final data = response.data;
      if (data == null) {
        return Result.failure('No quote returned from Odos');
      }

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'Odos quote failed: ${e.message}',
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
      final pathId = quote.metadata['pathId'];
      if (pathId == null) {
        return Result.failure('Missing pathId in quote metadata');
      }

      final body = {
        'userAddr': userAddress,
        'pathId': pathId,
        'simulate': false,
      };

      final response = await _dio.post(
        '$_baseUrl/sor/assemble',
        data: body,
      );

      final data = response.data;
      final transaction = data['transaction'];

      if (transaction == null) {
        return Result.failure('No transaction data returned');
      }

      return Result.success(
        EvmTransaction(
          from: transaction['from'] ?? userAddress,
          to: transaction['to'],
          data: transaction['data'],
          value: BigInt.parse(transaction['value']?.toString() ?? '0'),
          gasLimit: BigInt.parse(transaction['gas']?.toString() ?? '500000'),
          gasPrice:
              BigInt.tryParse(transaction['gasPrice']?.toString() ?? '0') ??
                  BigInt.zero,
          chainId: quote.params.fromChain,
          summary: TransactionSummary(
            action: 'Swap',
            fromAsset: quote.params.fromToken,
            toAsset: quote.params.toToken,
            inputAmount: quote.inputAmount,
            expectedOutput: quote.outputAmount,
            protocol: name,
          ),
          metadata: data,
        ),
      );
    } on DioException catch (e) {
      return Result.failure(
        'Odos tx build failed: ${e.message}',
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
    return Result.failure(
        'Status check not supported. Monitor chain for txHash: $txHash',
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
    return Result.success(
        '0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559'); // Odos V2
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final amountIn = BigInt.parse(data['inAmounts']?[0]?.toString() ?? '0');
    final amountOut = BigInt.parse(data['outAmounts']?[0]?.toString() ?? '0');

    final decimalIn = (Decimal.fromBigInt(amountIn) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.fromTokenDecimals)))
        .toDecimal();

    final decimalOut = (Decimal.fromBigInt(amountOut) /
            Decimal.fromBigInt(BigInt.from(10).pow(params.toTokenDecimals)))
        .toDecimal();

    final exchangeRate = decimalIn > Decimal.zero
        ? (decimalOut / decimalIn).toDecimal()
        : Decimal.zero;

    // Odos returns gas estimate in USD or native
    final gasEstimate = BigInt.parse(data['gasEstimate']?.toString() ?? '0');

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
        gasLimit: gasEstimate,
        gasPrice: BigInt
            .zero, // Usually need separate fetch or from quote if available
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact:
          double.tryParse(data['priceImpact']?.toString() ?? '0') ?? 0.0,
      protocols: ['Odos V2'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
