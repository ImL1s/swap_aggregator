import 'package:decimal/decimal.dart';
import 'package:swap_aggregator/swap_aggregator.dart';
import 'package:test/test.dart';

// Manual Mock for SwapProviderInterface
class MockSwapProvider extends SwapProviderInterface {
  final String _name;
  final Result<SwapQuote>? _quoteResult;
  final Result<SwapTransaction>? _txResult;

  MockSwapProvider(this._name,
      {Result<SwapQuote>? quoteResult, Result<SwapTransaction>? txResult})
      : _quoteResult = quoteResult,
        _txResult = txResult;

  @override
  String get name => _name;

  @override
  List<ChainId> get supportedChains => [ChainId.ethereum];

  @override
  bool get supportsCrossChain => false;

  @override
  bool isChainSupported(ChainId chainId) => supportedChains.contains(chainId);

  @override
  bool isCrossChainSupported(ChainId fromChain, ChainId toChain) => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async {
    return Result.success([]);
  }

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async {
    return _quoteResult ?? Result.failure('No mock quote set');
  }

  @override
  Future<Result<SwapTransaction>> buildTransaction({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    return _txResult ?? Result.failure('No mock tx set');
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
  Future<Result<ApprovalTransaction>> getApprovalTransaction({
    required ChainId chainId,
    required String tokenAddress,
    BigInt? amount,
  }) async {
    return Result.success(ApprovalTransaction(
      tokenAddress: tokenAddress,
      spenderAddress: '0xSpender',
      amount: amount ?? BigInt.zero,
      chainId: chainId,
    ));
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) {
    return Future.value(Result.success('0xSpender'));
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.success(SwapStatus.pending(txHash));
  }

  @override
  void dispose() {}
}

void main() {
  group('SwapAggregatorService', () {
    late SwapParams defaultParams;

    setUp(() {
      defaultParams = SwapParams(
        fromToken: '0x1',
        toToken: '0x2', // using address for now as per test setup
        fromTokenAddress: '0x1',
        toTokenAddress: '0x2',
        amount: Decimal.parse('1.0'),
        fromChain: ChainId.ethereum,
        toChain: ChainId.ethereum,
        userAddress: '0xUser',
      );
    });

    test('getBestQuote returns the quote with highest output amount', () async {
      // Arrange
      final quote1 = SwapQuote(
        provider: 'Provider1',
        params: defaultParams,
        inputAmount: Decimal.parse('1.0'),
        outputAmount: Decimal.parse('100.0'),
        minimumOutputAmount: Decimal.parse('99.0'),
        exchangeRate: Decimal.parse('100.0'),
        routes: [],
        gasEstimate: GasEstimate(
          gasLimit: BigInt.from(21000),
          gasPrice: BigInt.from(1000000000), // 1 gwei
          estimatedCost: Decimal.parse('0.000021'),
          nativeSymbol: 'ETH',
        ),
        priceImpact: 0.1,
        protocols: [],
        validUntil: DateTime.now().millisecondsSinceEpoch + 60000,
        timestamp: DateTime.now(),
        metadata: {},
      );

      final quote2 = SwapQuote(
        provider: 'Provider2',
        params: defaultParams,
        inputAmount: Decimal.parse('1.0'),
        outputAmount: Decimal.parse('105.0'), // Better rate
        minimumOutputAmount: Decimal.parse('104.0'),
        exchangeRate: Decimal.parse('105.0'),
        routes: [],
        gasEstimate: GasEstimate(
          gasLimit: BigInt.from(21000),
          gasPrice: BigInt.from(1000000000),
          estimatedCost: Decimal.parse('0.000021'),
          nativeSymbol: 'ETH',
        ),
        priceImpact: 0.1,
        protocols: [],
        validUntil: DateTime.now().millisecondsSinceEpoch + 60000,
        timestamp: DateTime.now(),
        metadata: {},
      );

      final provider1 =
          MockSwapProvider('Provider1', quoteResult: Result.success(quote1));
      final provider2 =
          MockSwapProvider('Provider2', quoteResult: Result.success(quote2));

      final aggregator =
          SwapAggregatorService(providers: [provider1, provider2]);

      // Act
      final result = await aggregator.getBestQuote(defaultParams);

      // Assert
      expect(result.isSuccess, isTrue);
      // Access value safely by casting to Success
      final success = result as Success<SwapQuote>;
      expect(success.value.provider, equals('Provider2'));
      expect(success.value.outputAmount, equals(Decimal.parse('105.0')));
    });

    test('getBestQuote returns valid quote even if some providers fail',
        () async {
      // Arrange
      final quote1 = SwapQuote(
        provider: 'Provider1',
        params: defaultParams,
        inputAmount: Decimal.parse('1.0'),
        outputAmount: Decimal.parse('100.0'),
        minimumOutputAmount: Decimal.parse('99.0'),
        exchangeRate: Decimal.parse('100.0'),
        routes: [],
        gasEstimate: GasEstimate(
          gasLimit: BigInt.from(21000),
          gasPrice: BigInt.from(1000000000),
          estimatedCost: Decimal.parse('0.000021'),
          nativeSymbol: 'ETH',
        ),
        priceImpact: 0.1,
        protocols: [],
        validUntil: DateTime.now().millisecondsSinceEpoch + 60000,
        timestamp: DateTime.now(),
        metadata: {},
      );

      final provider1 =
          MockSwapProvider('Provider1', quoteResult: Result.success(quote1));
      final provider2 = MockSwapProvider('Provider2',
          quoteResult: Result.failure('Network error'));

      final aggregator =
          SwapAggregatorService(providers: [provider2, provider1]);

      // Act
      final result = await aggregator.getBestQuote(defaultParams);

      // Assert
      expect(result.isSuccess, isTrue);
      final success = result as Success<SwapQuote>;
      expect(success.value.provider, equals('Provider1'));
    });

    test('getBestQuote fails if all providers fail', () async {
      // Arrange
      final provider1 =
          MockSwapProvider('Provider1', quoteResult: Result.failure('Error 1'));
      final provider2 =
          MockSwapProvider('Provider2', quoteResult: Result.failure('Error 2'));

      final aggregator =
          SwapAggregatorService(providers: [provider1, provider2]);

      // Act
      final result = await aggregator.getBestQuote(defaultParams);

      // Assert
      expect(result.isFailure, isTrue);
    });
  });
}
