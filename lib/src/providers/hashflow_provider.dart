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

/// Hashflow Provider
///
/// RFQ-based protocol with guaranteed pricing and MEV protection.
/// API Docs: https://docs.hashflow.com/
class HashflowProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.hashflow.com/taker/v3';

  final Dio _dio;
  final String _sourceId;

  HashflowProvider({Dio? dio, String sourceId = 'multi-chain-wallet'})
      : _dio = dio ?? Dio(),
        _sourceId = sourceId {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  @override
  String get name => 'Hashflow';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.bsc,
        ChainId.polygon,
        ChainId.avalanche,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.base,
        ChainId.solana,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    return Result.success([]);
  }

  Map<String, dynamic> _mapChainToHashflow(ChainId chainId) {
    // Hashflow uses { chainType: 'evm', chainId: 1 } or { chainType: 'solana', network: 'mainnet' }
    if (chainId == ChainId.solana) {
      return {'chainType': 'solana', 'network': 'mainnet-beta'};
    }
    return {'chainType': 'evm', 'chainId': chainId.id};
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final body = {
        'source': _sourceId,
        'baseChain': _mapChainToHashflow(params.fromChain),
        'quoteChain': _mapChainToHashflow(params.toChain),
        'rfqs': [
          {
            'baseToken': params.fromTokenAddress,
            'quoteToken': params.toTokenAddress,
            'baseTokenAmount': params.amountInSmallestUnit.toString(),
            'trader': params.userAddress,
          }
        ],
      };

      final response = await _dio.post(
        '$_baseUrl/rfq',
        data: body,
      );

      final data = response.data;
      if (data == null ||
          data['rfqs'] == null ||
          (data['rfqs'] as List).isEmpty) {
        return Result.failure('No quote from Hashflow');
      }

      final rfqResult = data['rfqs'][0];
      if (rfqResult['error'] != null) {
        return Result.failure('Hashflow RFQ error: ${rfqResult['error']}');
      }

      return Result.success(_parseQuote(rfqResult, params, data));
    } on DioException catch (e) {
      return Result.failure(
        'Hashflow quote failed: ${e.message}',
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
    final rfq = quote.metadata['rfq'];
    final signature = quote.metadata['signature'];

    if (rfq == null || signature == null) {
      return Result.failure('Missing RFQ data or signature in Hashflow quote');
    }

    try {
      if (quote.params.fromChain == ChainId.solana) {
        return Result.success(SolanaTransaction(
          base64EncodedTransaction: rfq['transactionData'] ?? '',
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

      final routerRes = await getSpenderAddress(quote.params.fromChain);
      final routerAddress = routerRes.isSuccess
          ? routerRes.valueOrNull!
          : '0xHashflowRouterAddressPlaceholder';

      return Result.success(
        EvmTransaction(
          from: userAddress,
          to: routerAddress,
          data:
              '0xTradeRFQT_CallData_Placeholder', // Encode tradeRFQT(rfq, signature)
          value: quote.params.fromTokenAddress.toLowerCase() == 'native' ||
                  quote.params.fromTokenAddress ==
                      '0x0000000000000000000000000000000000000000'
              ? quote.params.amountInSmallestUnit
              : BigInt.zero,
          gasLimit: BigInt.from(300000),
          gasPrice: BigInt.zero,
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
      return Result.failure('Failed to build Hashflow transaction: $e');
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
    return Result.failure('On-chain tracking recommended for Hashflow',
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
    // Each chain has a specific Hashflow Router
    switch (chainId) {
      case ChainId.ethereum:
      case ChainId.arbitrum:
      case ChainId.optimism:
      case ChainId.polygon:
      case ChainId.bsc:
      case ChainId.avalanche:
      case ChainId.base:
        // Hashflow Router (HashflowFactory/Pool) for EVM chains
        return Result.success('0xdE828fdc3F497F16416D1bB645261C7C6a62DAb5');
      // Add more as per Hashflow docs
      default:
        return Result.failure(
            'Hashflow router address not configured for $chainId');
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> rfqResult, SwapParams params,
      Map<String, dynamic> fullData) {
    final amountIn =
        BigInt.parse(rfqResult['baseTokenAmount']?.toString() ?? '0');
    final amountOut =
        BigInt.parse(rfqResult['quoteTokenAmount']?.toString() ?? '0');

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
      minimumOutputAmount: decimalOut, // RFQ guarantees this amount
      exchangeRate: decimalIn > Decimal.zero
          ? (decimalOut / decimalIn).toDecimal()
          : Decimal.zero,
      routes: [],
      gasEstimate:
          GasEstimate.zero(nativeSymbol: params.fromChain.nativeSymbol),
      priceImpact: 0.0,
      protocols: ['Hashflow RFQ'],
      validUntil:
          int.tryParse(rfqResult['quoteExpiry']?.toString() ?? '0') ?? 0,
      timestamp: DateTime.now(),
      metadata: {
        'rfq': rfqResult,
        'signature': rfqResult['signature'],
        'fullResponse': fullData,
      },
    );
  }
}
