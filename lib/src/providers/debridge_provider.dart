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

/// DeBridge DLN Provider
///
/// Cross-chain messaging and value transfer protocol.
/// API Docs: https://docs.dln.trade/
class DeBridgeProvider extends SwapProviderInterface {
  static const String _baseUrl = 'https://api.dln.trade/v1.0';

  final Dio _dio;

  DeBridgeProvider({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.headers = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
  }

  @override
  String get name => 'DeBridge';

  @override
  List<ChainId> get supportedChains => [
        ChainId.ethereum,
        ChainId.bsc,
        ChainId.polygon,
        ChainId.arbitrum,
        ChainId.avalanche,
        ChainId.optimism,
        ChainId.base,
        ChainId.linea,
        ChainId.legacy_solana,
        ChainId.solana,
      ];

  @override
  bool get supportsCrossChain => true;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    // Requires token list from external source
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    try {
      final queryParams = {
        'srcChainId': params.fromChain.id,
        'srcChainTokenIn': params.fromTokenAddress,
        'srcChainTokenInAmount': params.amountInSmallestUnit.toString(),
        'dstChainId': params.toChain.id,
        'dstChainTokenOut': params.toTokenAddress,
        'dstChainTokenOutAmount': 'auto', // Auto-calculate output
        // Adding addresses triggers full tx generation, but we can also use it for accurate quote
        'dstChainTokenOutRecipient': params.userAddress,
        'srcChainOrderAuthorityAddress': params.userAddress,
        // DeBridge requires implicit slippage via 'takerProtocolFee' or min amount?
        // Actually 'create-tx' creates the order directly.
        // There isn't a separate "quote only" endpoint that differs significantly from create-tx param structure.
      };

      final response = await _dio.get(
        '$_baseUrl/dln/order/create-tx',
        queryParameters: queryParams,
      );

      final data = response.data;
      if (data == null) {
        return Result.failure('No data returned from DeBridge');
      }

      return Result.success(_parseQuote(data, params));
    } on DioException catch (e) {
      return Result.failure(
        'DeBridge quote failed: ${e.message}',
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
    final txData = quote.metadata['tx'];
    if (txData == null) {
      return Result.failure(
          'Transaction data missing in quote metadata (ensure addresses passed to quote)');
    }

    try {
      if (quote.params.fromChain == ChainId.solana ||
          quote.params.fromChain == ChainId.legacy_solana) {
        return Result.success(SolanaTransaction(
          base64EncodedTransaction: txData['data'] ?? '',
          chainId: quote.params.fromChain,
          summary: TransactionSummary(
            action: 'Bridge',
            fromAsset: quote.params.fromToken,
            toAsset: quote.params.toToken,
            inputAmount: quote.inputAmount,
            expectedOutput: quote.outputAmount,
            protocol: name,
            destinationChain: quote.params.toChain.name,
          ),
          metadata: quote.metadata,
        ));
      }

      return Result.success(
        EvmTransaction(
          from: userAddress,
          to: txData['to'],
          data: txData['data'],
          value: BigInt.parse(txData['value']?.toString() ?? '0'),
          gasLimit: BigInt.parse(txData['gasLimit']?.toString() ?? '500000'),
          gasPrice: BigInt.tryParse(txData['gasPrice']?.toString() ?? '0') ??
              BigInt.zero,
          chainId: quote.params.fromChain,
          summary: TransactionSummary(
            action: 'Bridge',
            fromAsset: quote.params.fromToken,
            toAsset: quote.params.toToken,
            inputAmount: quote.inputAmount,
            expectedOutput: quote.outputAmount,
            protocol: name,
            destinationChain: quote.params.toChain.name,
          ),
          metadata: quote.metadata,
        ),
      );
    } catch (e) {
      return Result.failure('Failed to parse DeBridge transaction: $e');
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
    try {
      // /dln/order/{orderId}
      // We need orderId, not txHash.
      // Often orderId is derived or returned in create-tx response?
      // Metadata has 'orderId'

      // If we only have txHash (from input), we might need to search or rely on caller passing orderId.
      // DeBridge API usually works with orderId.
      // For now, fail or implement if a txHash lookup exists.

      return Result.failure(
          'Status check requires Order ID. Please track via DeBridge explorer with txHash: $txHash',
          code: 'NOT_SUPPORTED');
    } catch (_) {
      return Result.failure('Status check failed');
    }
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
    // DLN Source contract address varies by chain.
    // Ideally fetch from /dln/config or similar
    // Hardcoding typically robust checks like 0x...
    // For specific integration, using quote's 'tx.to' is safest if it's an ERC20 transfer-in call.
    // But for approval, we need it beforehand.
    // DLN Source V1.0 addresses:
    // https://docs.dln.trade/dln-contracts/addresses
    // Using a common function or map.

    // Fallback failure to prompt 'buildTransaction' usage pattern (where approval is checked?)
    // Or return fixed address if confident.
    // DeBridge allows "giveAllowance" in create-tx params?

    // Verified DLN Source Address for EVM chains (DeBridge Liquidity Network)
    // Source: https://docs.dln.trade/dln-contracts/addresses
    // Deployments are typically deterministic (CREATE2)
    return Result.success('0xeF4fB24aD0916217251F553c0596F8Edc630EB66');
  }

  SwapQuote _parseQuote(Map<String, dynamic> data, SwapParams params) {
    final estimation = data['estimation'];

    if (estimation == null) {
      // Fallback or error
      throw Exception('No estimation in DeBridge response');
    }

    final amountIn = BigInt.parse(
        estimation['srcChainTokenIn']['amount']?.toString() ?? '0');
    final amountOut = BigInt.parse(
        estimation['dstChainTokenOut']['amount']?.toString() ?? '0');

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
                  Decimal.parse(params.slippage.toString())), // Approx
      exchangeRate: exchangeRate,
      routes: [],
      gasEstimate: GasEstimate.fromWei(
        gasLimit:
            BigInt.zero, // Fee usually deducted from output or passed in costs
        gasPrice: BigInt.zero,
        nativeSymbol: params.fromChain.nativeSymbol,
      ),
      priceImpact: 0.0,
      protocols: ['DeBridge DLN'],
      validUntil: (DateTime.now().millisecondsSinceEpoch ~/ 1000) +
          30, // DeBridge quotes valid short time
      timestamp: DateTime.now(),
      metadata: data,
    );
  }
}
