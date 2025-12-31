import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:swap_aggregator/src/core/models/approval_method.dart';
import 'package:swap_aggregator/src/core/models/chain_id.dart';
import 'package:swap_aggregator/src/core/models/chain_transaction.dart';
import 'package:swap_aggregator/src/core/models/gas_estimate.dart';
import 'package:swap_aggregator/src/core/models/swap_params.dart';
import 'package:swap_aggregator/src/core/models/swap_quote.dart';

import 'package:swap_aggregator/src/providers/one_inch_provider.dart';
import 'package:test/test.dart';

import 'one_inch_provider_test.mocks.dart';

@GenerateNiceMocks([MockSpec<Dio>()])
void main() {
  late OneInchProvider provider;
  late MockDio mockDio;

  setUp(() {
    mockDio = MockDio();
    when(mockDio.options).thenReturn(BaseOptions());
    provider = OneInchProvider(dio: mockDio);
  });

  group('OneInchProvider', () {
    final mockParams = SwapParams(
      fromChain: ChainId.ethereum,
      toChain: ChainId.ethereum,
      fromToken: 'ETH',
      toToken: 'USDC',
      fromTokenAddress: '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      toTokenAddress: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
      amount: Decimal.one,
      userAddress: '0xUser',
    );

    final mockQuote = SwapQuote(
      provider: '1inch',
      params: mockParams,
      inputAmount: Decimal.one,
      outputAmount: Decimal.parse('2000'),
      minimumOutputAmount: Decimal.parse('1990'),
      exchangeRate: Decimal.parse('2000'),
      routes: [],
      gasEstimate: GasEstimate(
        gasLimit: BigInt.from(200000),
        gasPrice: BigInt.zero,
        estimatedCost: Decimal.zero,
        nativeSymbol: 'ETH',
      ),
      priceImpact: 0.0,
      protocols: [],
      validUntil: 0,
      timestamp: DateTime.now(),
      metadata: {},
    );

    test('buildTransactionV2 returns EvmTransaction', () async {
      when(mockDio.get(
        any,
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {
              'tx': {
                'from': '0xUser',
                'to': '0xRouter',
                'data': '0xData',
                'value': '1000000000000000000',
                'gas': 200000,
                'gasPrice': '20000000000',
              }
            },
          ));

      final result = await provider.buildTransactionV2(
        quote: mockQuote,
        userAddress: '0xUser',
      );

      expect(result.isSuccess, isTrue);
      final tx = result.valueOrNull!;
      expect(tx, isA<EvmTransaction>());
      final evmTx = tx as EvmTransaction;
      expect(evmTx.to, '0xRouter');
      expect(evmTx.value, BigInt.from(1000000000000000000));
      expect(evmTx.summary.action, 'Swap');
      expect(evmTx.summary.protocol, '1inch');
    });

    test('getApprovalMethod returns NoApprovalNeeded when allowance sufficient',
        () async {
      // Mock allowance response
      when(mockDio.get(
        argThat(contains('/allowance')),
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'allowance': '1000000000000000000000'}, // > amount
          ));

      final result = await provider.getApprovalMethod(
        chainId: ChainId.ethereum,
        tokenAddress: '0xToken',
        ownerAddress: '0xUser',
        amount: BigInt.from(1000),
      );

      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull!, isA<NoApprovalNeeded>());
    });

    test(
        'getApprovalMethod returns StandardApproval when allowance insufficient',
        () async {
      // Mock allowance response (insufficient)
      when(mockDio.get(
        argThat(contains('/allowance')),
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'allowance': '0'},
          ));

      // Mock spender response
      when(mockDio.get(
        argThat(contains('/spender')),
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {'address': '0xRouter'},
          ));

      // Mock approval tx response
      when(mockDio.get(
        argThat(contains('/approve/transaction')),
        queryParameters: anyNamed('queryParameters'),
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: {
              'to': '0xToken',
              'data': '0xApprove',
              'value': '0',
              'gasPrice': '20000000000',
              'gas': 50000,
            },
          ));

      final result = await provider.getApprovalMethod(
        chainId: ChainId.ethereum,
        tokenAddress: '0xToken',
        ownerAddress: '0xUser',
        amount: BigInt.from(1000),
      );

      expect(result.isSuccess, isTrue);
      final method = result.valueOrNull!;
      expect(method, isA<StandardApproval>());
      final approval = method as StandardApproval;
      expect(approval.spenderAddress, '0xRouter');
      expect(approval.amount, BigInt.from(1000));
      expect(approval.transaction.data, '0xApprove');
    });
  });
}
