import 'package:decimal/decimal.dart';
// import 'package:swap_aggregator/src/aggregator/quote_comparator.dart';
import 'package:swap_aggregator/swap_aggregator.dart';
import 'package:test/test.dart';

void main() {
  group('QuoteComparator', () {
    late SwapQuote quoteHighOutput;
    late SwapQuote quoteLowOutput;
    late SwapQuote quoteHighGas;

    setUp(() {
      final baseParams = SwapParams(
        fromChain: ChainId.ethereum,
        toChain: ChainId.ethereum,
        fromToken: 'ETH',
        toToken: 'USDC',
        fromTokenAddress: '',
        toTokenAddress: '',
        amount: Decimal.parse('1.0'),
        userAddress: '',
      );

      quoteHighOutput = _msg(
        baseParams,
        output: '2000.0',
        gasCost: '10.0',
      ); // Net: 1990

      quoteLowOutput = _msg(
        baseParams,
        output: '1900.0',
        gasCost: '5.0',
      ); // Net: 1895

      quoteHighGas = _msg(
        baseParams,
        output: '2010.0',
        gasCost: '50.0',
      ); // Net: 1960
    });

    test('sorts by effective rate (output - gas)', () {
      final quotes = [quoteLowOutput, quoteHighGas, quoteHighOutput];
      final sorted = QuoteComparator.sortQuotes(quotes);

      // Expected order:
      // 1. quoteHighOutput (1990)
      // 2. quoteHighGas (1960)
      // 3. quoteLowOutput (1895)

      expect(sorted[0], equals(quoteHighOutput));
      expect(sorted[1], equals(quoteHighGas));
      expect(sorted[2], equals(quoteLowOutput));
    });

    test('sorts by raw output when ignoring gas', () {
      final quotes = [quoteLowOutput, quoteHighGas, quoteHighOutput];
      final sorted = QuoteComparator.sortQuotes(quotes, considerGas: false);

      // Expected order:
      // 1. quoteHighGas (2010)
      // 2. quoteHighOutput (2000)
      // 3. quoteLowOutput (1900)

      expect(sorted[0], equals(quoteHighGas));
      expect(sorted[1], equals(quoteHighOutput));
      expect(sorted[2], equals(quoteLowOutput));
    });
  });
}

SwapQuote _msg(SwapParams params,
    {required String output, required String gasCost}) {
  return SwapQuote(
    provider: 'Test',
    params: params,
    inputAmount: params.amount,
    outputAmount: Decimal.parse(output),
    minimumOutputAmount: Decimal.zero,
    exchangeRate: Decimal.zero,
    routes: [],
    gasEstimate: GasEstimate(
      gasLimit: BigInt.zero,
      gasPrice: BigInt.zero,
      estimatedCost: Decimal.zero,
      estimatedCostInToken: Decimal.parse(gasCost),
      nativeSymbol: 'ETH',
    ),
    priceImpact: 0,
    protocols: [],
    validUntil: 0,
    timestamp: DateTime.now(),
    metadata: {},
  );
}
