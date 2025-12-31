import 'package:decimal/decimal.dart';
import 'package:swap_aggregator/swap_aggregator.dart';
import 'package:test/test.dart';

void main() {
  group('SwapParams', () {
    test('props equality', () {
      final params1 = SwapParams(
        fromChain: ChainId.ethereum,
        toChain: ChainId.polygon,
        fromToken: 'ETH',
        toToken: 'MATIC',
        fromTokenAddress: '0x00...01',
        toTokenAddress: '0x00...02',
        amount: Decimal.parse('1.0'),
        userAddress: '0xUser',
      );

      final params2 = SwapParams(
        fromChain: ChainId.ethereum,
        toChain: ChainId.polygon,
        fromToken: 'ETH',
        toToken: 'MATIC',
        fromTokenAddress: '0x00...01',
        toTokenAddress: '0x00...02',
        amount: Decimal.parse('1.0'),
        userAddress: '0xUser',
      );

      expect(params1, equals(params2));
    });

    test('amountInSmallestUnit calculation', () {
      final params = SwapParams(
        fromChain: ChainId.ethereum,
        toChain: ChainId.ethereum,
        fromToken: 'ETH',
        toToken: 'USDC',
        fromTokenAddress: 'native',
        toTokenAddress: '0x...',
        amount: Decimal.parse('1.5'),
        userAddress: '0xUser',
        fromTokenDecimals: 18,
      );

      // 1.5 * 10^18
      expect(params.amountInSmallestUnit, BigInt.parse('1500000000000000000'));
    });
  });

  group('SwapQuote', () {
    test('effectiveRate calculation', () {
      final quote = SwapQuote(
        provider: 'Test',
        params: SwapParams(
          fromChain: ChainId.ethereum,
          toChain: ChainId.ethereum,
          fromToken: 'ETH',
          toToken: 'USDC',
          fromTokenAddress: '',
          toTokenAddress: '',
          amount: Decimal.parse('1.0'),
          userAddress: '',
        ),
        inputAmount: Decimal.parse('1.0'),
        outputAmount: Decimal.parse('2000.0'),
        minimumOutputAmount: Decimal.parse('1990.0'),
        exchangeRate: Decimal.parse('2000.0'),
        routes: [],
        gasEstimate: GasEstimate(
          gasLimit: BigInt.zero,
          gasPrice: BigInt.zero,
          estimatedCost: Decimal.parse('0.01'), // 0.01 ETH gas
          estimatedCostInToken: Decimal.parse('20.0'), // $20 gas
          nativeSymbol: 'ETH',
        ),
        priceImpact: 0.1,
        protocols: [],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {},
      );

      // Net output = 2000 - 20 = 1980
      // Effective rate = 1980 / 1.0 = 1980
      expect(quote.effectiveRate, Decimal.parse('1980.0'));
    });
  });
}
