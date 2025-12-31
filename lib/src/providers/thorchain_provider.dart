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

/// ThorChain Provider (via SwapKit API)
///
/// Native cross-chain swaps (BTC, ETH, etc.) using THORChain.
/// API Docs: https://api.swapkit.dev/
class ThorChainProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.swapkit.dev';

  final Dio _dio;
  final String? _apiKey;

  ThorChainProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (_apiKey != null) 'x-api-key': _apiKey,
    };
  }

  @override
  String get name => 'ThorChain';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.bsc,
        ChainId.avalanche,
        ChainId.cosmos, // ATOM
        ChainId.bitcoin,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    return Result.success([]);
  }

  String _getAssetString(ChainId chainId, String tokenAddress, String symbol) {
    String chain;
    switch (chainId) {
      case ChainId.ethereum:
        chain = 'ETH';
        break;
      case ChainId.bsc:
        chain = 'BSC';
        break;
      case ChainId.avalanche:
        chain = 'AVAX';
        break;
      case ChainId.cosmos:
        chain = 'GAIA';
        break;
      case ChainId.bitcoin:
        chain = 'BTC';
        break;
      default:
        chain = chainId.name.toUpperCase();
    }

    if (tokenAddress.toLowerCase().contains('eeee') ||
        tokenAddress == 'native') {
      return '$chain.$chain';
    }

    return '$chain.$symbol-$tokenAddress';
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final sellAsset = _getAssetString(
          params.fromChain, params.fromTokenAddress, params.fromToken);
      final buyAsset = _getAssetString(
          params.toChain, params.toTokenAddress, params.toToken);

      final amountDecimal =
          Decimal.parse(params.amountInSmallestUnit.toString()) /
              Decimal.fromBigInt(BigInt.from(10).pow(params.fromTokenDecimals));

      final body = {
        'sellAsset': sellAsset,
        'buyAsset': buyAsset,
        'sellAmount': amountDecimal.toString(),
        'sourceAddress': params.userAddress,
        'destinationAddress': params.userAddress,
        'slippage': params.slippage.toString(),
        'providers': ['THORCHAIN'],
      };

      final response = await _dio.post(
        '$_baseUrl/quote',
        data: body,
      );

      final data = response.data;
      if (data['error'] != null) {
        return Result.failure(data['error']);
      }

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'ThorChain quote failed: ${e.message}',
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
    final metadata = quote.metadata;
    final String? memo = metadata['memo'] ?? metadata['memo_swap'];
    final String? inboundAddress =
        metadata['inbound_address'] ?? metadata['vault'];

    if (inboundAddress == null) {
      return Result.failure('Missing inbound address for THORChain swap');
    }

    final fromChain = quote.params.fromChain;

    try {
      if (fromChain.isEvm) {
        return Result.success(EvmTransaction(
          from: userAddress,
          to: inboundAddress,
          data: memo != null ? '0x${_encodeMemo(memo)}' : '0x',
          value: quote.params.amountInSmallestUnit,
          gasLimit: BigInt.from(100000),
          gasPrice: BigInt.zero,
          chainId: fromChain,
          summary: _createSummary(quote),
          metadata: metadata,
        ));
      } else if (fromChain == ChainId.bitcoin) {
        return Result.success(UtxoTransaction(
          inputs: [],
          outputs: [
            UtxoOutput(
                address: inboundAddress,
                value: quote.params.amountInSmallestUnit),
          ],
          feeRateSatPerVb: 0,
          chainId: fromChain,
          summary: _createSummary(quote),
          metadata: {...metadata, 'memo': memo},
        ));
      } else if (fromChain == ChainId.cosmos) {
        return Result.success(CosmosTransaction(
          messages: [
            CosmosMessage(
              typeUrl: '/cosmos.bank.v1beta1.MsgSend',
              value: {
                'from_address': userAddress,
                'to_address': inboundAddress,
                'amount': [
                  {
                    'denom': 'uatom',
                    'amount': quote.params.amountInSmallestUnit.toString()
                  }
                ],
              },
            ),
          ],
          fee: CosmosFee(
            amount: [CosmosCoin(denom: 'uatom', amount: BigInt.from(5000))],
            gasLimit: BigInt.from(200000),
          ),
          memo: memo ?? '',
          chainId: fromChain,
          summary: _createSummary(quote),
          metadata: metadata,
        ));
      }

      return Result.failure(
          'Chain ${fromChain.name} not fully supported by THORChain provider migration yet');
    } catch (e) {
      return Result.failure('Failed to build THORChain transaction: $e');
    }
  }

  String _encodeMemo(String memo) {
    return memo.codeUnits
        .map((e) => e.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  TransactionSummary _createSummary(SwapQuote quote) {
    return TransactionSummary(
      action: 'Swap',
      fromAsset: quote.params.fromToken,
      toAsset: quote.params.toToken,
      inputAmount: quote.inputAmount,
      expectedOutput: quote.outputAmount,
      destinationChain: quote.params.toChain.name,
      protocol: name,
    );
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
      return Result.failure(result.errorOrNull!);
    }

    final tx = result.valueOrNull;
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

    return Result.failure('V1 buildTransaction only supports EVM results');
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.failure(
        'Status check implementation requires Thornode integration',
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
    try {
      if (tokenAddress.toLowerCase().contains('eeee') ||
          tokenAddress == 'native') {
        return Result.success(
            NoApprovalNeeded(reason: 'Native asset does not require approval'));
      }

      final spenderResult = await getSpenderAddress(chainId);
      if (spenderResult.isFailure) {
        return Result.failure(spenderResult.errorOrNull!);
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
    } catch (e) {
      return Result.failure('Failed to get THORChain approval method: $e');
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

    if (result.isFailure) {
      return Result.failure(result.errorOrNull!);
    }

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

    return Result.failure('No approval transaction needed or available');
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    try {
      final response = await _dio.get('$_baseUrl/thorchain/inbound_addresses');
      final List<dynamic> data = response.data;

      String chainCode;
      switch (chainId) {
        case ChainId.ethereum:
          chainCode = 'ETH';
          break;
        case ChainId.bsc:
          chainCode = 'BSC';
          break;
        case ChainId.avalanche:
          chainCode = 'AVAX';
          break;
        default:
          return Result.failure('Chain not supported for Vault extraction');
      }

      final chainData = data.cast<Map<String, dynamic>>().firstWhere(
            (e) => e['chain'] == chainCode,
            orElse: () => <String, dynamic>{},
          );

      if (chainData.isNotEmpty) {
        return Result.success(chainData['address']);
      }
      return Result.failure('Chain $chainCode not found in inbound addresses');
    } catch (e) {
      return Result.failure('Failed to fetch inbound addresses: $e');
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final route = (data['routes'] as List?)?.firstOrNull;
    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: Decimal.parse(params.amountInSmallestUnit.toString()),
      outputAmount: Decimal.parse(route?['buyAmount']?.toString() ?? '0'),
      minimumOutputAmount: Decimal.zero,
      exchangeRate: Decimal.zero,
      routes: [],
      gasEstimate:
          GasEstimate.zero(nativeSymbol: params.fromChain.nativeSymbol),
      priceImpact: 0.0,
      protocols: ['THORChain'],
      validUntil: 0,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
