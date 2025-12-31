import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:swap_aggregator/src/core/models/chain_id.dart';
import 'package:swap_aggregator/src/core/models/chain_transaction.dart';
import 'package:swap_aggregator/src/core/models/gas_estimate.dart';
import 'package:swap_aggregator/src/core/models/swap_params.dart';
import 'package:swap_aggregator/src/core/models/swap_quote.dart';
import 'package:swap_aggregator/src/providers/rango_provider.dart';
import 'package:swap_aggregator/src/utils/result.dart';
import 'package:test/test.dart';

import 'rango_provider_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late RangoProvider provider;

  setUp(() {
    mockDio = MockDio();
    when(mockDio.options).thenReturn(BaseOptions());
    provider = RangoProvider(apiKey: 'test-api-key', dio: mockDio);
  });

  group('RangoProvider', () {
    final userAddress = '0xUserAddress';
    final requestId = 'request-123';

    test('buildTransactionV2 returns EvmTransaction', () async {
      final quote = SwapQuote(
        provider: 'Rango',
        params: SwapParams(
          fromChain: ChainId.ethereum,
          toChain: ChainId.bsc,
          fromToken: 'ETH',
          toToken: 'BNB',
          fromTokenAddress: '0xETH',
          toTokenAddress: '0xBNB',
          amount: Decimal.one,
          userAddress: userAddress,
        ),
        inputAmount: Decimal.one,
        outputAmount: Decimal.fromInt(10),
        minimumOutputAmount: Decimal.fromInt(9),
        exchangeRate: Decimal.fromInt(10),
        routes: [],
        gasEstimate: GasEstimate.zero(nativeSymbol: 'ETH'),
        priceImpact: 0.1,
        protocols: [],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {'requestId': requestId},
      );

      when(mockDio.get(argThat(contains('basic/swap')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'resultType': 'OK',
                  'tx': {
                    'type': 'EVM',
                    'txTo': '0xRouter',
                    'txData': '0x1234',
                    'value': '0',
                    'gasLimit': '300000',
                    'gasPrice': '1000000000',
                  }
                },
                statusCode: 200,
              ));

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: userAddress,
      );

      expect(result.isSuccess, true);
      final tx = (result as Success<ChainTransaction>).value as EvmTransaction;
      expect(tx.to, '0xRouter');
      expect(tx.chainId, ChainId.ethereum);
    });

    test('buildTransactionV2 returns SolanaTransaction', () async {
      final quote = SwapQuote(
        provider: 'Rango',
        params: SwapParams(
          fromChain: ChainId.solana,
          toChain: ChainId.ethereum,
          fromToken: 'SOL',
          toToken: 'ETH',
          fromTokenAddress: 'native',
          toTokenAddress: '0xETH',
          amount: Decimal.one,
          userAddress: 'SolAddress',
        ),
        inputAmount: Decimal.one,
        outputAmount: Decimal.fromInt(1),
        minimumOutputAmount: Decimal.fromInt(0),
        exchangeRate: Decimal.one,
        routes: [],
        gasEstimate: GasEstimate.zero(nativeSymbol: 'SOL'),
        priceImpact: 0.1,
        protocols: [],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {'requestId': requestId},
      );

      when(mockDio.get(argThat(contains('basic/swap')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'resultType': 'OK',
                  'tx': {
                    'type': 'SOLANA',
                    'txData': 'Base64TxMsg',
                  }
                },
                statusCode: 200,
              ));

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: 'SolAddress',
      );

      expect(result.isSuccess, true);
      final tx =
          (result as Success<ChainTransaction>).value as SolanaTransaction;
      expect(tx.base64EncodedTransaction, 'Base64TxMsg');
      expect(tx.chainId, ChainId.solana);
    });
  });
}
