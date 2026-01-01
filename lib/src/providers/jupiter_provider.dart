import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

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
import '../utils/unit_utils.dart';

/// Jupiter Aggregator Provider (Solana)
///
/// Uses Jupiter v6 API for best-in-class Solana swaps.
/// API Docs: https://station.jup.ag/docs/apis/swap-api
///
/// ## Example
/// ```dart
/// final jupiter = JupiterProvider();
/// final quote = await jupiter.getQuote(params);
/// ```
class JupiterProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://quote-api.jup.ag/v6';

  final Dio _dio;

  JupiterProvider({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  @override
  String get name => 'Jupiter';

  @override
  List<ChainId> get supportedChains => [ChainId.solana];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // Jupiter strictly uses Solana token list
    // Ideally this should fetch from https://token.jup.ag/strict
    try {
      final response = await _dio.get('https://token.jup.ag/strict');
      final List<dynamic> data = response.data;

      final tokens = data.map((json) {
        return Token(
          symbol: json['symbol'] ?? 'UNKNOWN',
          name: json['name'] ?? 'Unknown Token',
          address: json['address'],
          decimals: json['decimals'] ?? 9,
          chainId: ChainId.solana,
          logoUrl: json['logoURI'],
        );
      }).toList();

      return Result.success(tokens);
    } catch (e) {
      return Result.failure('Failed to fetch Jupiter strict token list: $e');
    }
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    if (params.fromChain != ChainId.solana ||
        params.toChain != ChainId.solana) {
      return Result.failure('Jupiter only supports Solana');
    }

    try {
      final queryParams = {
        'inputMint': params.fromTokenAddress,
        'outputMint': params.toTokenAddress,
        'amount': params.amountInSmallestUnit.toString(),
        'slippageBps': (params.slippage * 100).toInt(),
        'swapMode': 'ExactIn',
      };

      final response = await _dio.get(
        '$_baseUrl/quote',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data == null) {
        return Result.failure('No quote returned from Jupiter');
      }

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'Jupiter quote failed: ${e.message}',
        code: 'QUOTE_ERROR',
        details: e.response?.data,
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  @override
  Future<Result<SwapTransaction>> buildTransaction({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    try {
      final body = {
        'userPublicKey': userAddress,
        'wrapAndUnwrapSol': true,
        'useSharedAccounts': true,
        'prioritizationFeeLamports': 'auto',
        'quoteResponse': quote.metadata,
      };

      final response = await _dio.post(
        '$_baseUrl/swap',
        data: body,
      );

      final data = response.data;
      final swapTransaction = data['swapTransaction']; // Base64 encoded tx

      if (swapTransaction == null) {
        return Result.failure('No transaction data returned');
      }

      // Jupiter returns a single base64 transaction string
      return Result.success(
        SwapTransaction(
          from: userAddress,
          to: 'Jupiter V6 Router', // Logical destination
          data: swapTransaction, // This is the Base64 serialized transaction
          value: BigInt.zero, // Value is inside the instruction
          gasLimit: BigInt.zero, // Solana fee handled internally
          gasPrice: BigInt.zero,
          chainId: ChainId.solana,
          metadata: data,
        ),
      );
    } on DioException catch (e) {
      return Result.failure(
        'Jupiter swap build failed: ${e.message}',
        code: 'TX_BUILD_ERROR',
        details: e.response?.data,
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    // Jupiter doesn't have a status API, status is on-chain
    return Result.failure(
      'Status check not supported via Jupiter API. Monitor Solana chain directly.',
      code: 'NOT_SUPPORTED',
    );
  }

  @override
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    // Solana doesn't have allowances like EVM
    return Result.success(BigInt.zero);
  }

  @override
  Future<Result<ApprovalTransaction>> getApprovalTransaction({
    required ChainId chainId,
    required String tokenAddress,
    BigInt? amount,
  }) async {
    return Result.failure('Solana does not require approvals');
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    return Result.failure('Not applicable for Solana');
  }

  @override
  Future<Result<ChainTransaction>> buildTransactionV2({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    try {
      final body = {
        'userPublicKey': userAddress,
        'wrapAndUnwrapSol': true,
        'useSharedAccounts': true,
        'prioritizationFeeLamports': 'auto',
        'quoteResponse': quote.metadata,
      };

      final response = await _dio.post(
        '$_baseUrl/swap',
        data: body,
      );

      final data = response.data;
      final swapTransaction = data['swapTransaction'];

      if (swapTransaction == null) {
        return Result.failure('No transaction data returned');
      }

      return Result.success(SolanaTransaction(
        base64EncodedTransaction: swapTransaction,
        requiredSigners: [userAddress],
        chainId: ChainId.solana,
        metadata: data,
        summary: TransactionSummary(
          action: 'Swap',
          fromAsset: quote.params.fromToken,
          toAsset: quote.params.toToken,
          inputAmount: quote.inputAmount,
          expectedOutput: quote.outputAmount,
          protocol: name,
        ),
      ));
    } on DioException catch (e) {
      return Result.failure(
        'Jupiter swap build failed: ${e.message}',
        code: 'TX_BUILD_ERROR',
        details: e.response?.data,
      );
    } catch (e) {
      return Result.failure('Unexpected error: $e');
    }
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final outAmount = BigInt.parse(data['outAmount']?.toString() ?? '0');
    final inAmount = BigInt.parse(data['inAmount']?.toString() ?? '0');

    final decimalIn =
        UnitUtils.fromTokenUnit(inAmount, params.fromTokenDecimals);
    final decimalOut =
        UnitUtils.fromTokenUnit(outAmount, params.toTokenDecimals);

    // Calculate exchange rate
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
      routes: _parseRoutes(data['routePlan']),
      gasEstimate: GasEstimate(
        gasLimit: BigInt.zero, // Solana fees are different
        gasPrice: BigInt.zero,
        estimatedCost: Decimal.zero,
        nativeSymbol: 'SOL',
      ),
      priceImpact:
          double.tryParse(data['priceImpactPct']?.toString() ?? '0') ?? 0.0,
      protocols: ['Jupiter V6'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 60,
      timestamp: DateTime.now(),
      metadata: data,
    );
  }

  List<SwapRoute> _parseRoutes(dynamic routePlan) {
    if (routePlan is! List) return [];

    final steps = routePlan.map<SwapStep>((step) {
      if (step is Map) {
        final swapInfo = step['swapInfo'];
        return SwapStep(
          fromToken: swapInfo?['inputMint']?.toString() ?? '',
          toToken: swapInfo?['outputMint']?.toString() ?? '',
          protocol: swapInfo?['label']?.toString() ?? 'Jupiter AMM',
          expectedOutput:
              Decimal.parse(swapInfo?['outAmount']?.toString() ?? '0'),
        );
      }
      return SwapStep(
        fromToken: '',
        toToken: '',
        protocol: 'Unknown',
        expectedOutput: Decimal.zero,
      );
    }).toList();

    return [
      SwapRoute(
        protocol: 'Jupiter Aggregator',
        portion: 100,
        steps: steps,
      )
    ];
  }
}
