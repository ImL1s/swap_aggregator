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

/// Bebop API Provider
/// Zero-slippage RFQ (Request-for-Quote) based swaps.
class BebopProvider extends SwapProviderInterface {
  final Dio _dio;
  final String? _apiKey;

  BebopProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      if (_apiKey != null) 'Authorization': 'Bearer $_apiKey',
    };
  }

  @override
  String get name => 'Bebop';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.polygon,
        ChainId.arbitrum,
        ChainId.bsc,
        ChainId.base,
        ChainId.optimism,
        ChainId.zksync,
      ];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    return Result.failure(
        'Token list not directly supported by Bebop provider');
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final chain = _mapChainToName(params.fromChain);
      if (chain == null) return Result.failure('Chain not supported by Bebop');

      final response = await _dio.get(
        'https://api.bebop.xyz/$chain/v2/quote',
        queryParameters: {
          'buy_tokens': params.toTokenAddress,
          'sell_tokens': params.fromTokenAddress,
          'sell_amounts': params.amountInSmallestUnit.toString(),
          'taker_address': params.userAddress,
          'approval_type': 'Standard',
        },
      );

      final data = response.data;
      if (data['buy_tokens'] == null) {
        return Result.failure('Bebop quote error or no routes');
      }

      final quote = _parseTokenQuote(data['buy_tokens'][0], params, data);
      return Result.success(quote);
    } catch (e) {
      return Result.failure('Bebop quote failed: $e');
    }
  }

  @override
  Future<Result<ChainTransaction>> buildTransactionV2({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    final raw = quote.metadata;
    if (raw['to'] == null || raw['tx'] == null) {
      return Result.failure('Bebop transaction data missing from quote');
    }

    final tx = raw['tx'];
    try {
      return Result.success(
        EvmTransaction(
          from: userAddress,
          to: raw['to'],
          data: tx['data'],
          value: BigInt.parse(tx['value']?.toString() ?? '0'),
          gasLimit: BigInt.parse(tx['gas']?.toString() ?? '300000'),
          gasPrice: BigInt.parse(tx['gasPrice']?.toString() ?? '0'),
          chainId: quote.params.fromChain,
          summary: TransactionSummary(
            action: 'Swap',
            fromAsset: quote.params.fromToken,
            toAsset: quote.params.toToken,
            inputAmount: quote.inputAmount,
            expectedOutput: quote.outputAmount,
            protocol: name,
          ),
          metadata: raw,
        ),
      );
    } catch (e) {
      return Result.failure('Failed to parse Bebop transaction: $e');
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
    // This would typically involve a contract call.
    // Since we don't have a direct API for this in Bebop,
    // we return a success with 0 or a logical failure.
    // However, we can return the spender address for the user to check externally.
    return Result.failure(
        'Bebop requires manual allowance check via spender address');
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
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    // Bebop uses a universal spender address for PMM RFQ
    return Result.success('0xbbbbbBB520d69a9775E85b458C58c648259FAD5F');
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.failure('Status tracking not implemented for Bebop');
  }

  String? _mapChainToName(ChainId chain) {
    switch (chain) {
      case ChainId.ethereum:
        return 'ethereum';
      case ChainId.polygon:
        return 'polygon';
      case ChainId.arbitrum:
        return 'arbitrum';
      case ChainId.bsc:
        return 'bsc';
      case ChainId.base:
        return 'base';
      case ChainId.optimism:
        return 'optimism';
      case ChainId.zksync:
        return 'zksync';
      default:
        return null;
    }
  }

  SwapQuote _parseTokenQuote(Map<String, dynamic> tokenData, SwapParams params,
      Map<String, dynamic> raw) {
    final amountOut = Decimal.parse(tokenData['amount'].toString());
    final decimals =
        int.tryParse(tokenData['decimals']?.toString() ?? '18') ?? 18;

    final divisor = Decimal.fromBigInt(BigInt.from(10).pow(decimals));
    final humanAmountOut = (amountOut / divisor).toDecimal();

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: params.amount,
      outputAmount: humanAmountOut,
      minimumOutputAmount: humanAmountOut, // Bebop is 0% slippage
      exchangeRate: (humanAmountOut / params.amount).toDecimal(),
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit: BigInt.parse(raw['gas_fee']?.toString() ?? '0'),
        gasPrice: BigInt.zero, // Included in gas_fee usually
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: 0.0,
      protocols: ['Bebop PMM'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 30,
      timestamp: DateTime.now(),
      metadata: raw,
    );
  }
}
