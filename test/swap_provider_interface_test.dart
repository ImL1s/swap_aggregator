import 'package:decimal/decimal.dart';
import 'package:test/test.dart';
import 'package:swap_aggregator/swap_aggregator.dart';

// Concrete implementation for testing abstract class logic
class TestSwapProvider extends SwapProviderInterface {
  final Result<SwapTransaction>? buildTxResult;
  final Result<ApprovalTransaction>? approvalTxResult;
  final Result<BigInt>? allowanceResult;
  final Result<String>? spenderResult;

  TestSwapProvider({
    this.buildTxResult,
    this.approvalTxResult,
    this.allowanceResult,
    this.spenderResult,
  });

  @override
  String get name => 'TestProvider';

  @override
  List<ChainId> get supportedChains => [ChainId.ethereum, ChainId.solana];

  @override
  bool get supportsCrossChain => false;

  @override
  Future<Result<List<Token>>> getTokens(ChainId chainId) async =>
      Result.success([]);

  @override
  Future<Result<SwapQuote>> getQuote(SwapParams params) async =>
      Result.failure('Not implemented');

  @override
  Future<Result<SwapTransaction>> buildTransaction({
    required SwapQuote quote,
    required String userAddress,
    String? recipientAddress,
  }) async {
    return buildTxResult ?? Result.failure('Mock buildTransaction failed');
  }

  @override
  Future<Result<BigInt>> checkAllowance({
    required ChainId chainId,
    required String tokenAddress,
    required String ownerAddress,
  }) async {
    return allowanceResult ?? Result.success(BigInt.zero);
  }

  @override
  Future<Result<ApprovalTransaction>> getApprovalTransaction({
    required ChainId chainId,
    required String tokenAddress,
    BigInt? amount,
  }) async {
    return approvalTxResult ??
        Result.failure('Mock getApprovalTransaction failed');
  }

  @override
  Future<Result<String>> getSpenderAddress(ChainId chainId) async {
    return spenderResult ?? Result.success('0xRouter');
  }

  @override
  Future<Result<SwapStatus>> getSwapStatus({
    required String txHash,
    required ChainId chainId,
  }) async {
    return Result.success(SwapStatus.pending(txHash));
  }
}

void main() {
  group('SwapProviderInterface Default Logic', () {
    final mockQuote = SwapQuote(
      provider: 'TestProvider',
      params: SwapParams(
        fromChain: ChainId.ethereum,
        toChain: ChainId.ethereum,
        fromToken: 'ETH',
        toToken: 'USDC',
        fromTokenAddress: '',
        toTokenAddress: '',
        amount: Decimal.one,
        userAddress: '',
      ),
      inputAmount: Decimal.one,
      outputAmount: Decimal.parse('2000'),
      minimumOutputAmount: Decimal.parse('1990'),
      exchangeRate: Decimal.parse('2000'),
      routes: [],
      gasEstimate: GasEstimate(
          gasLimit: BigInt.zero,
          gasPrice: BigInt.zero,
          estimatedCost: Decimal.zero,
          nativeSymbol: 'ETH'),
      priceImpact: 0.0,
      protocols: [],
      validUntil: 0,
      timestamp: DateTime.now(),
      metadata: {},
    );

    group('buildTransactionV2', () {
      test('wraps buildTransaction result into EvmTransaction', () async {
        final provider = TestSwapProvider(
          buildTxResult: Result.success(SwapTransaction(
            from: '0xUser',
            to: '0xRouter',
            data: '0xData',
            value: BigInt.from(100),
            gasLimit: BigInt.from(21000),
            gasPrice: BigInt.from(10),
            chainId: ChainId.ethereum,
            metadata: {},
          )),
        );

        final result = await provider.buildTransactionV2(
          quote: mockQuote,
          userAddress: '0xUser',
        );

        expect(result.isSuccess, isTrue);
        final tx = result.valueOrNull!;
        expect(tx, isA<EvmTransaction>());

        final evmTx = tx as EvmTransaction;
        expect(evmTx.from, '0xUser');
        expect(evmTx.to, '0xRouter');
        expect(evmTx.summary.protocol, 'TestProvider');
      });

      test('propagates failure from buildTransaction', () async {
        final provider = TestSwapProvider(
          buildTxResult: Result.failure('Build failed'),
        );

        final result = await provider.buildTransactionV2(
          quote: mockQuote,
          userAddress: '0xUser',
        );

        expect(result.isFailure, isTrue);
        expect(result.errorOrNull, 'Build failed');
      });
    });

    group('getApprovalMethod', () {
      test('returns NoApprovalNeeded for Solana', () async {
        final provider = TestSwapProvider(
          spenderResult: Result.failure('Not applicable for Solana'),
        );

        final result = await provider.getApprovalMethod(
          chainId: ChainId.solana,
          tokenAddress: 'TokenX',
          ownerAddress: 'User1',
          amount: BigInt.from(100),
        );

        expect(result.isSuccess, isTrue);
        final method = result.valueOrNull!;
        expect(method, isA<NoApprovalNeeded>());
        expect((method as NoApprovalNeeded).reason, contains('Solana'));
      });

      test('returns NoApprovalNeeded if allowance is sufficient', () async {
        final provider = TestSwapProvider(
          allowanceResult: Result.success(BigInt.from(1000)), // > 500
        );

        final result = await provider.getApprovalMethod(
          chainId: ChainId.ethereum,
          tokenAddress: '0xToken',
          ownerAddress: '0xUser',
          amount: BigInt.from(500),
        );

        expect(result.isSuccess, isTrue);
        expect(result.valueOrNull!, isA<NoApprovalNeeded>());
        expect((result.valueOrNull! as NoApprovalNeeded).reason,
            contains('Sufficient allowance'));
      });

      test('returns StandardApproval if allowance is insufficient', () async {
        final provider = TestSwapProvider(
          allowanceResult: Result.success(BigInt.from(100)), // < 500
          approvalTxResult: Result.success(ApprovalTransaction(
            tokenAddress: '0xToken',
            spenderAddress: '0xRouter',
            amount: BigInt.from(500),
            chainId: ChainId.ethereum,
            transaction: SwapTransaction(
              from: '0xUser',
              to: '0xToken',
              data: '0xApprove',
              value: BigInt.zero,
              gasLimit: BigInt.from(50000),
              gasPrice: BigInt.zero,
              chainId: ChainId.ethereum,
              metadata: {},
            ),
          )),
        );

        final result = await provider.getApprovalMethod(
          chainId: ChainId.ethereum,
          tokenAddress: '0xToken',
          ownerAddress: '0xUser',
          amount: BigInt.from(500),
        );

        expect(result.isSuccess, isTrue);
        final method = result.valueOrNull!;
        expect(method, isA<StandardApproval>());

        final standard = method as StandardApproval;
        expect(standard.amount, BigInt.from(500));
        expect(standard.transaction.data, '0xApprove');
      });

      test('propagates failure from getApprovalTransaction', () async {
        final provider = TestSwapProvider(
          allowanceResult: Result.success(BigInt.zero),
          approvalTxResult: Result.failure('Approval build failed'),
        );

        final result = await provider.getApprovalMethod(
          chainId: ChainId.ethereum,
          tokenAddress: '0xToken',
          ownerAddress: '0xUser',
          amount: BigInt.from(500),
        );

        expect(result.isFailure, isTrue);
        expect(result.errorOrNull, 'Approval build failed');
      });
    });
  });
}
