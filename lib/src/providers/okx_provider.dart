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

/// OKX DEX Aggregator Provider
class OKXProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://www.okx.com/api/v6/dex/aggregator';

  final Dio _dio;
  final String? _apiKey;

  OKXProvider({Dio? dio, String? apiKey})
      : _dio = dio ?? Dio(),
        _apiKey = apiKey {
    _dio.options.headers = {
      'Accept': 'application/json',
      if (_apiKey != null) 'OK-ACCESS-KEY': _apiKey,
    };
  }

  @override
  String get name => 'OKX DEX';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.bsc,
        ChainId.polygon,
        ChainId.avalanche,
        ChainId.arbitrum,
        ChainId.optimism,
        ChainId.base,
        ChainId.fantom,
        ChainId.gnosis,
        ChainId.zksync,
        ChainId.linea,
        ChainId.scroll,
        ChainId.mantle,
        ChainId.blast,
        ChainId.solana,
        ChainId.tron,
        ChainId.sui,
        ChainId.aptos,
        ChainId.metis,
        ChainId.moonbeam,
        ChainId.moonriver,
        ChainId.celo,
        ChainId.cronos,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    try {
      final chainIndex = _mapChainToId(chainId);
      if (chainIndex == null)
        return Result.failure('Chain not supported by OKX');

      final response = await _dio.get(
        'https://www.okx.com/api/v6/dex/aggregator/tokens',
        queryParameters: {'chainId': chainIndex},
      );

      if (response.data['code'] != '0') {
        return Result.failure(response.data['msg'] ?? 'OKX tokens error');
      }

      final List<dynamic> data = response.data['data'];
      final tokens = data.map((t) {
        return Token(
          symbol: t['tokenSymbol'] ?? 'UNKNOWN',
          name: t['tokenName'] ?? '',
          address: t['tokenContractAddress'],
          decimals: int.tryParse(t['decimals']?.toString() ?? '18') ?? 18,
          chainId: chainId,
          logoUrl: t['tokenLogoUrl'],
        );
      }).toList();

      return Result.success(tokens);
    } catch (e) {
      return Result.failure('OKX tokens failed: $e');
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final chainId = _mapChainToId(params.fromChain);
      if (chainId == null) return Result.failure('Chain not supported by OKX');

      final response = await _dio.get(
        '$_baseUrl/quote',
        queryParameters: {
          'chainId': chainId,
          'amount': params.amountInSmallestUnit.toString(),
          'fromTokenAddress': params.fromTokenAddress,
          'toTokenAddress': params.toTokenAddress,
          'slippage': (params.slippage / 100).toString(),
        },
      );

      if (response.data['code'] != '0') {
        return Result.failure(response.data['msg'] ?? 'OKX quote error');
      }

      final quote = _parseQuote(response.data['data'][0], params);
      return Result.success(quote);
    } catch (e) {
      return Result.failure('OKX quote failed: $e');
    }
  }

  @override
  Future<Result<ChainTransaction>> buildTransactionV2({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    try {
      final chainId = _mapChainToId(quote.params.fromChain);
      if (chainId == null) return Result.failure('Chain not supported by OKX');

      final response = await _dio.get(
        '$_baseUrl/swap',
        queryParameters: {
          'chainId': chainId,
          'amount': quote.params.amountInSmallestUnit.toString(),
          'fromTokenAddress': quote.params.fromTokenAddress,
          'toTokenAddress': quote.params.toTokenAddress,
          'userWalletAddress': userAddress,
          'slippage': (quote.params.slippage / 100).toString(),
          if (recipientAddress != null) 'toWalletAddress': recipientAddress,
        },
      );

      if (response.data['code'] != '0') {
        return Result.failure(response.data['msg'] ?? 'OKX swap error');
      }

      final data = response.data['data'][0];
      final txData = data['tx'];

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
          metadata: data,
        ));
      }

      // Handle EVM, Tron, etc.
      return Result.success(
        EvmTransaction(
          from: txData['from'] ?? userAddress,
          to: txData['to'],
          data: txData['data'],
          value: BigInt.parse(txData['value']?.toString() ?? '0'),
          gasLimit: BigInt.parse(txData['gas']?.toString() ?? '500000'),
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
          metadata: data,
        ),
      );
    } catch (e) {
      return Result.failure('OKX transaction build failed: $e');
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
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    try {
      final chainIndex = _mapChainToId(chainId);
      if (chainIndex == null)
        return Result.failure('Chain not supported by OKX');

      final response = await _dio.get(
        '$_baseUrl/approve/allowance',
        queryParameters: {
          'chainId': chainIndex,
          'tokenContractAddress': tokenAddress,
          'userWalletAddress': ownerAddress,
        },
      );

      if (response.data['code'] != '0') {
        return Result.failure(response.data['msg'] ?? 'OKX allowance error');
      }

      final allowance = BigInt.parse(
        response.data['data'][0]['allowanceAmount']?.toString() ?? '0',
      );
      return Result.success(allowance);
    } catch (e) {
      return Result.failure('OKX allowance check failed: $e');
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
      final chainIndex = _mapChainToId(chainId);
      if (chainIndex == null)
        return Result.failure('Chain not supported by OKX');

      final response = await _dio.get(
        '$_baseUrl/approve/transaction',
        queryParameters: {
          'chainId': chainIndex,
          'tokenContractAddress': tokenAddress,
          'approveAmount': amount.toString(),
        },
      );

      if (response.data['code'] != '0') {
        return Result.failure(response.data['msg'] ?? 'OKX approval error');
      }

      final data = response.data['data'][0];
      final spender = data['spender'];

      final tx = EvmTransaction(
        from: ownerAddress,
        to: data['to'],
        data: data['data'],
        value: BigInt.parse(data['value']?.toString() ?? '0'),
        gasLimit: BigInt.parse(data['gasLimit']?.toString() ?? '100000'),
        gasPrice: BigInt.parse(data['gasPrice']?.toString() ?? '0'),
        chainId: chainId,
        summary: TransactionSummary(
          action: 'Approve',
          fromAsset: tokenAddress,
          toAsset: tokenAddress,
          inputAmount: Decimal.zero,
          expectedOutput: Decimal.zero,
          protocol: name,
        ),
        metadata: data,
      );

      return Result.success(StandardApproval(
        transaction: tx,
        tokenAddress: tokenAddress,
        spenderAddress: spender,
        amount: amount,
      ));
    } catch (e) {
      return Result.failure('OKX approval method failed: $e');
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
    try {
      final chainIndex = _mapChainToId(chainId);
      if (chainIndex == null)
        return Result.failure('Chain not supported by OKX');

      final response = await _dio.get(
        '$_baseUrl/approve/spender',
        queryParameters: {'chainId': chainIndex},
      );

      if (response.data['code'] != '0') {
        return Result.failure(response.data['msg'] ?? 'OKX spender error');
      }

      return Result.success(response.data['data'][0]['spender']);
    } catch (e) {
      return Result.failure('OKX spender failed: $e');
    }
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    try {
      final chainIndex = _mapChainToId(chainId);
      if (chainIndex == null)
        return Result.failure('Chain not supported by OKX');

      final response = await _dio.get(
        '$_baseUrl/history',
        queryParameters: {
          'chainId': chainIndex,
          'txHash': txHash,
        },
      );

      if (response.data['code'] != '0') {
        return Result.failure(response.data['msg'] ?? 'OKX history error');
      }

      final dataList = response.data['data'] as List;
      if (dataList.isEmpty) {
        return Result.success(SwapStatus.pending(txHash));
      }

      final data = dataList[0];
      final status = data['status']?.toString().toLowerCase();

      if (status == 'success') {
        return Result.success(SwapStatus.completed(txHash));
      } else if (status == 'fail') {
        return Result.success(SwapStatus.failed(
            txHash, data['errorMsg'] ?? 'OKX reported failure'));
      }

      return Result.success(SwapStatus.pending(txHash));
    } catch (e) {
      return Result.failure('OKX status check failed: $e');
    }
  }

  String? _mapChainToId(ChainId chain) {
    switch (chain) {
      case ChainId.ethereum:
        return '1';
      case ChainId.bsc:
        return '56';
      case ChainId.polygon:
        return '137';
      case ChainId.avalanche:
        return '43114';
      case ChainId.arbitrum:
        return '42161';
      case ChainId.optimism:
        return '10';
      case ChainId.base:
        return '8453';
      case ChainId.fantom:
        return '250';
      case ChainId.gnosis:
        return '100';
      case ChainId.zksync:
        return '324';
      case ChainId.linea:
        return '59144';
      case ChainId.scroll:
        return '534352';
      case ChainId.mantle:
        return '5000';
      case ChainId.blast:
        return '81457';
      case ChainId.solana:
        return '501';
      case ChainId.tron:
        return '1000';
      case ChainId.sui:
        return '784';
      case ChainId.aptos:
        return '757';
      case ChainId.metis:
        return '1088';
      case ChainId.moonbeam:
        return '1284';
      case ChainId.moonriver:
        return '1285';
      case ChainId.celo:
        return '42220';
      case ChainId.cronos:
        return '25';
      default:
        return null;
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final toToken = data['toToken'];
    final toAmount = Decimal.parse(data['toTokenAmount'].toString());
    final decimals = int.parse(toToken['decimal'].toString());

    final divisor = Decimal.fromBigInt(BigInt.from(10).pow(decimals));
    final outAmount = (toAmount / divisor).toDecimal();

    return SwapQuote(
      provider: name,
      params: params,
      inputAmount: params.amount,
      outputAmount: outAmount,
      minimumOutputAmount:
          (outAmount * Decimal.parse((1 - params.slippage / 100).toString())),
      exchangeRate: (outAmount / params.amount).toDecimal(),
      routes: [], // Detailed route info available in data['router'] if needed
      gasEstimate: GasEstimate.fromWei(
        gasLimit: BigInt.parse(data['gasLimit']?.toString() ?? '0'),
        gasPrice: BigInt.parse(data['gasPrice']?.toString() ?? '0'),
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact:
          double.tryParse(data['priceImpact']?.toString() ?? '0.0') ?? 0.0,
      protocols: [],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
