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

/// Rango Exchange Provider (Cross-chain)
///
/// Requires an API key for production use.
/// Get your API key at https://rango.exchange/
///
/// API Documentation: https://docs.rango.exchange/
/// Token format: {BLOCKCHAIN}.{SYMBOL} for native, {BLOCKCHAIN}--{ADDRESS} for tokens
///
/// ## Example
/// ```dart
/// final rango = RangoProvider(apiKey: 'your-api-key');
/// final quote = await rango.getQuote(params);
/// ```
class RangoProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.rango.exchange';

  final Dio _dio;
  final String _apiKey;

  // Cache for metadata
  Map<String, dynamic>? _metaCache;
  DateTime? _lastMetaUpdate;

  RangoProvider({required String apiKey, Dio? dio})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  @override
  String get name => 'Rango';

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
        ChainId.linea,
        ChainId.zksync,
        ChainId.tron,
        ChainId.solana,
        ChainId.cosmos,
        ChainId.osmosis,
        ChainId.ton,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      await _ensureMetaCache();

      final blockchain = _getBlockchainName(chainId);
      if (blockchain == null) return Result.success([]);

      final tokens = (_metaCache?['tokens'] as List? ?? [])
          .where((t) => t['blockchain'] == blockchain)
          .map(
            (t) => Token(
              symbol: t['symbol'] as String,
              name: t['name'] as String? ?? t['symbol'] as String,
              address: t['address'] as String? ?? 'native',
              decimals: t['decimals'] as int? ?? 18,
              chainId: chainId,
              logoUrl: t['image'] as String?,
              isNative: t['address'] == null,
            ),
          )
          .toList();

      return Result.success(tokens);
    } catch (e) {
      return Result.failure('Failed to fetch tokens: $e');
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final fromBlockchain = _getBlockchainName(params.fromChain);
      final toBlockchain = _getBlockchainName(params.toChain);

      if (fromBlockchain == null || toBlockchain == null) {
        return Result.failure('Unsupported chain', code: 'UNSUPPORTED_CHAIN');
      }

      final fromSymbol = _formatTokenSymbol(
        fromBlockchain,
        params.fromTokenAddress,
        params.fromToken,
      );
      final toSymbol = _formatTokenSymbol(
        toBlockchain,
        params.toTokenAddress,
        params.toToken,
      );

      // Rango API format: from/to use {BLOCKCHAIN}.{SYMBOL} or {BLOCKCHAIN}--{ADDRESS}
      final queryParams = {
        'apiKey': _apiKey,
        'from': fromSymbol,
        'to': toSymbol,
        'amount': params.amount.toString(),
        'slippage':
            (params.slippage / 100).toString(), // Rango expects 0.01 for 1%
      };

      final response = await _dio.get(
        '$_baseUrl/basic/quote',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data['resultType'] != 'OK') {
        return Result.failure(
          data['error'] ?? 'Failed to get quote',
          code: data['resultType'],
        );
      }

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
    try {
      final requestId = quote.metadata['requestId'] as String?;
      if (requestId == null) {
        return Result.failure('Missing requestId in Rango quote metadata');
      }

      final queryParams = {
        'apiKey': _apiKey,
        'requestId': requestId,
        'fromAddress': userAddress,
        'toAddress': recipientAddress ?? userAddress,
      };

      final response = await _dio.get(
        '$_baseUrl/basic/swap',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data['resultType'] != 'OK' || data['tx'] == null) {
        return Result.failure(
          data['error'] ?? 'Failed to build transaction',
          code: 'TX_BUILD_ERROR',
        );
      }

      final txData = data['tx'];
      final String type = txData['type'] ?? 'EVM';
      final fromChain = quote.params.fromChain;

      TransactionSummary summary = TransactionSummary(
        action: data['isApproval'] == true ? 'Approve' : 'Swap',
        fromAsset: quote.params.fromToken,
        toAsset: quote.params.toToken,
        inputAmount: quote.inputAmount,
        expectedOutput: quote.outputAmount,
        protocol: name,
        destinationChain: quote.params.toChain.name,
      );

      if (type == 'EVM') {
        // Add 20% safety buffer for gas (Rango already includes some)
        final estimatedGas =
            int.parse(txData['gasLimit']?.toString() ?? '500000');
        final gasWithBuffer = (estimatedGas * 1.2).round();

        return Result.success(EvmTransaction(
          from: userAddress,
          to: txData['txTo'] ?? txData['to'],
          data: txData['txData'] ?? txData['data'] ?? '',
          value: BigInt.parse(txData['value']?.toString() ?? '0'),
          gasLimit: BigInt.from(gasWithBuffer),
          gasPrice: BigInt.parse(txData['gasPrice']?.toString() ?? '0'),
          chainId: fromChain,
          summary: summary,
          metadata: data,
        ));
      } else if (type == 'SOLANA') {
        return Result.success(SolanaTransaction(
          base64EncodedTransaction:
              txData['txData'] ?? txData['data'], // Base64
          chainId: fromChain,
          summary: summary,
          metadata: data,
        ));
      } else if (type == 'COSMOS') {
        // Rango Cosmos format for basic/swap: Amino JSON usually
        final cosmosData = txData['txData'] ?? txData['data'];
        return Result.success(CosmosTransaction(
          messages: [], // Will be parsed by the wallet service from raw data if needed
          fee: CosmosFee(
            amount: [],
            gasLimit: BigInt.parse(txData['gasLimit']?.toString() ?? '300000'),
          ),
          memo: txData['memo'] ?? '',
          chainId: fromChain,
          summary: summary,
          metadata: {...data, 'rawCosmosTx': cosmosData},
        ));
      }

      return Result.failure('Unsupported Rango transaction type: $type');
    } on DioException catch (e) {
      return Result.failure(
        'Failed to build transaction: ${e.message}',
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
        'V1 buildTransaction only supports EVM results from Rango');
  }

  @override
  Future<Result<ApprovalMethod>> getApprovalMethod({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
    required BigInt amount,
  }) async {
    // Rango's basic/swap will return an approval tx if needed.
    // However, to support getApprovalMethod independently, we might need a requestId.
    // If this is called within the aggregator flow, we usually have a quote.
    // Since this interface method doesn't take a quote, we have to return NoApprovalNeeded
    // and let buildTransactionV2 handle the actual approval tx if Rango provides it.
    // Alternatively, we can return StandardApproval if we can identify the spender.
    return Result.success(NoApprovalNeeded(
        reason: 'Rango handles approvals via buildTransactionV2'));
  }

  @override
  @deprecated
  Future<Result<ApprovalTransaction>> getApprovalTransaction({
    required ChainId chainId,
    required String tokenAddress,
    BigInt? amount,
  }) async {
    return Result.failure('Use buildTransactionV2 for Rango approvals');
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
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    return Result.failure('Not applicable for Rango');
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    // For Rango, txHash should be the requestId
    try {
      final response = await _dio.get(
        '$_baseUrl/basic/status',
        queryParameters: {
          'apiKey': _apiKey,
          'requestId': txHash,
        },
      );

      final data = response.data;
      final statusStr = data['status'] as String?;
      final bridgeStatus = data['bridgeStatus'] as String?;

      SwapStatusType status;
      if (statusStr == 'SUCCESS') {
        status = SwapStatusType.completed;
      } else if (statusStr == 'FAILED') {
        status = SwapStatusType.failed;
      } else if (statusStr == 'RUNNING') {
        if (bridgeStatus == 'centralized_bridge_refund_tx_success' ||
            bridgeStatus == 'centralized_bridge_refund_tx_pending') {
          status = SwapStatusType.refunding;
        } else {
          status = SwapStatusType.processing;
        }
      } else {
        status = SwapStatusType.pending;
      }

      return Result.success(
        SwapStatus(
          txHash: txHash,
          status: status,
          metadata: data,
          outputTxHash: data['outputTransactionHash'],
          error: data['error'],
        ),
      );
    } on DioException catch (e) {
      return Result.failure(
        'Failed to get status: ${e.message}',
        code: 'STATUS_ERROR',
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  // --- Helper Methods ---

  Future<void> _ensureMetaCache() async {
    if (_metaCache != null &&
        _lastMetaUpdate != null &&
        DateTime.now().difference(_lastMetaUpdate!) <
            const Duration(hours: 1)) {
      return;
    }

    try {
      final response = await _dio.get(
        '$_baseUrl/basic/meta',
        queryParameters: {'apiKey': _apiKey},
      );
      _metaCache = response.data;
      _lastMetaUpdate = DateTime.now();
    } catch (e) {
      // Ignore error if cache exists
      if (_metaCache == null) rethrow;
    }
  }

  String? _getBlockchainName(ChainId chainId) {
    if (chainId == ChainId.ethereum) return 'ETH';
    if (chainId == ChainId.bsc) return 'BSC';
    if (chainId == ChainId.polygon) return 'POLYGON';
    if (chainId == ChainId.arbitrum) return 'ARBITRUM';
    if (chainId == ChainId.optimism) return 'OPTIMISM';
    if (chainId == ChainId.avalanche) return 'AVAX_CCHAIN';
    if (chainId == ChainId.fantom) return 'FANTOM';
    if (chainId == ChainId.base) return 'BASE';
    if (chainId == ChainId.linea) return 'LINEA';
    if (chainId == ChainId.zksync) return 'ZKSYNC';
    if (chainId == ChainId.tron) return 'TRON';
    if (chainId == ChainId.solana) return 'SOLANA';
    if (chainId == ChainId.osmosis) return 'OSMOSIS';
    if (chainId == ChainId.ton) return 'TON';
    if (chainId == ChainId.cosmos) return 'COSMOS';
    return null;
  }

  String _formatTokenSymbol(String blockchain, String address, String symbol) {
    // Native tokens
    if (_isNative(address, symbol)) {
      if (blockchain == 'ETH') return 'ETH.ETH';
      if (blockchain == 'BSC') return 'BSC.BNB';
      if (blockchain == 'POLYGON') return 'POLYGON.MATIC';
      return '$blockchain.$blockchain'; // Generic fallback
    }

    // ERC20/SPL/etc tokens
    // Rango format: BLOCKCHAIN--ADDRESS
    return '$blockchain--$address';
  }

  bool _isNative(String address, String symbol) {
    return address == 'native' ||
        address == '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE' ||
        address == '0x0000000000000000000000000000000000000000' ||
        address.isEmpty;
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final route = data['route'];
    final outputAmount = Decimal.parse(
      route['outputAmount']?.toString() ?? '0',
    );
    final inputAmount = params.amount;

    final minOutput = outputAmount *
        (Decimal.one -
            Decimal.parse('0.01') * Decimal.parse(params.slippage.toString()));

    final exchangeRate =
        inputAmount > Decimal.zero ? outputAmount / inputAmount : Decimal.zero;

    final estimatedGas = _extractEstimatedGas(route);

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: inputAmount,
      outputAmount: outputAmount,
      minimumOutputAmount: minOutput,
      exchangeRate: Decimal.parse(exchangeRate.toString()),
      routes: _parseRoutes(route),
      gasEstimate: GasEstimate(
        gasLimit: estimatedGas,
        gasPrice: BigInt.zero,
        estimatedCost: Decimal.zero, // Needs calculation from fees
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact:
          double.tryParse(route['priceImpact']?.toString() ?? '0') ?? 0.0,
      protocols: _extractProtocols(route),
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 300,
      timestamp: DateTime.now(),
      metadata: {...data, 'route': route},
    );
  }

  BigInt _extractEstimatedGas(Map<String, dynamic> route) {
    // Try to find gas estimates in fees
    // This is a simplified extraction
    return BigInt.from(500000); // Default fallback
  }

  List<SwapRoute> _parseRoutes(Map<String, dynamic> route) {
    // Rango provides a single path usually
    return [
      SwapRoute(
        protocol: 'Rango',
        portion: 100,
        steps: [], // Steps parsing omitted for brevity
      ),
    ];
  }

  List<String> _extractProtocols(Map<String, dynamic> route) {
    final protocols = <String>{};
    if (route['swappers'] != null) {
      for (final s in route['swappers'] as List) {
        if (s is Map && s['id'] != null) {
          protocols.add(s['id'].toString());
        }
      }
    }
    return protocols.toList();
  }
}
