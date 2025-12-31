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
import 'package:swap_aggregator/src/providers/openocean_provider.dart';
import 'package:swap_aggregator/src/utils/result.dart';
import 'package:test/test.dart';

import 'openocean_provider_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late OpenOceanProvider provider;

  setUp(() {
    mockDio = MockDio();
    when(mockDio.options).thenReturn(BaseOptions());
    provider = OpenOceanProvider(dio: mockDio);
  });

  group('OpenOceanProvider', () {
    final chainId = ChainId.ethereum;
    final userAddress = '0xUserAddress';
    final tokenAddress = '0xTokenAddress';
    final spenderAddress = '0x6352a56caadC4F1E25CD6c75970Fa768A3304e64';

    test('buildTransactionV2 returns EvmTransaction', () async {
      final quote = SwapQuote(
        provider: 'OpenOcean',
        params: SwapParams(
          fromChain: chainId,
          toChain: chainId,
          fromToken: 'ETH',
          toToken: 'USDC',
          fromTokenAddress: '0xETH',
          toTokenAddress: '0xUSDC',
          amount: Decimal.one,
          userAddress: userAddress,
        ),
        inputAmount: Decimal.one,
        outputAmount: Decimal.fromInt(2000),
        minimumOutputAmount: Decimal.fromInt(1990),
        exchangeRate: Decimal.fromInt(2000),
        routes: [],
        gasEstimate: GasEstimate.fromWei(
            gasLimit: BigInt.from(200000),
            gasPrice: BigInt.zero,
            nativeSymbol: 'ETH'),
        priceImpact: 0.1,
        protocols: [],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {},
      );

      when(mockDio.get(argThat(contains('swap_quote')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'code': 200,
                  'data': {
                    'from': userAddress,
                    'to': '0xRouter',
                    'data': '0x1234',
                    'value': '1000000000000000000',
                    'estimatedGas': '200000',
                    'gasPrice': '5000000000',
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
      expect(tx.value, BigInt.from(1000000000000000000));
      expect(tx.summary.toString(), 'Swap: 1 ETH → 2000 USDC via OpenOcean');
    });

    test(
        'getApprovalMethod returns NoApprovalNeeded when allowance is sufficient',
        () async {
      when(mockDio.get(argThat(contains('allowance')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {'code': 200, 'data': '1000000000000000000'},
                statusCode: 200,
              ));

      final result = await provider.getApprovalMethod(
        chainId: chainId,
        tokenAddress: tokenAddress,
        ownerAddress: userAddress,
        amount: BigInt.from(500),
      );

      expect(result.isSuccess, true);
      final method = (result as Success<ApprovalMethod>).value;
      expect(method is NoApprovalNeeded, true);
      expect((method as NoApprovalNeeded).reason, contains('sufficient'));
    });

    test(
        'getApprovalMethod returns StandardApproval when allowance is insufficient',
        () async {
      // 1. Mock allowance Check (Insufficient)
      when(mockDio.get(argThat(contains('allowance')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {'code': 200, 'data': '100'},
                statusCode: 200,
              ));

      // 2. Mock approve fetch
      when(mockDio.get(argThat(contains('approve')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'code': 200,
                  'data': {
                    'to': spenderAddress,
                    'data': '0xapprove_data',
                  }
                },
                statusCode: 200,
              ));

      final amount = BigInt.from(1000);
      final result = await provider.getApprovalMethod(
        chainId: chainId,
        tokenAddress: tokenAddress,
        ownerAddress: userAddress,
        amount: amount,
      );

      expect(result.isSuccess, true);
      final approval =
          (result as Success<ApprovalMethod>).value as StandardApproval;
      expect(approval.spenderAddress, spenderAddress);
      expect(approval.amount, amount);
      expect(approval.transaction.data, '0xapprove_data');
    });
  });
}
