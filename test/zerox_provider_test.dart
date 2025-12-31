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
import 'package:swap_aggregator/src/providers/zerox_provider.dart';
import 'package:swap_aggregator/src/utils/result.dart';
import 'package:test/test.dart';

import 'zerox_provider_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late ZeroXProvider provider;

  setUp(() {
    mockDio = MockDio();
    when(mockDio.options).thenReturn(BaseOptions());
    provider = ZeroXProvider(dio: mockDio);
  });

  group('ZeroXProvider', () {
    final chainId = ChainId.ethereum;
    final tokenAddress = '0x1111111111111111111111111111111111111111';
    final userAddress = '0xUserAddress';
    final spenderAddress = '0x0000000000001fF3684f28c67538d4D072C22734';

    test('buildTransactionV2 returns EvmTransaction', () async {
      final quote = SwapQuote(
        provider: '0x',
        params: SwapParams(
          fromChain: ChainId.ethereum,
          toChain: ChainId.ethereum,
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
            gasPrice: BigInt.from(5000000000),
            nativeSymbol: 'ETH'),
        priceImpact: 0.1,
        protocols: [],
        validUntil: 1234567890,
        timestamp: DateTime.now(),
        metadata: {
          'transaction': {
            'to': '0xZeroXRouter',
            'data': '0x123456',
            'value': '1000000000000000000',
            'gas': '500000',
            'gasPrice': '5000000000',
          }
        },
      );

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: userAddress,
      );

      expect(result.isSuccess, true);
      final tx = (result as Success<ChainTransaction>).value as EvmTransaction;
      expect(tx.to, '0xZeroXRouter');
      expect(tx.data, '0x123456');
      expect(tx.summary.toString(), 'Swap: 1 ETH → 2000 USDC via 0x');
    });

    test(
        'getApprovalMethod returns NoApprovalNeeded when issues.allowance is null',
        () async {
      when(mockDio.get(argThat(contains('price')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'issues': {'allowance': null}
                },
                statusCode: 200,
              ));

      final result = await provider.getApprovalMethod(
        chainId: chainId,
        tokenAddress: tokenAddress,
        ownerAddress: userAddress,
        amount: BigInt.from(1000),
      );

      expect(result.isSuccess, true);
      expect(
          (result as Success<ApprovalMethod>).value is NoApprovalNeeded, true);
    });

    test(
        'getApprovalMethod returns StandardApproval when issues.allowance is not null',
        () async {
      when(mockDio.get(argThat(contains('price')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'issues': {
                    'allowance': {
                      'spender': spenderAddress,
                      'actual': '0',
                      'expected': '1000'
                    }
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
      expect(
          approval.spenderAddress.toLowerCase(), spenderAddress.toLowerCase());
      expect(approval.amount, amount);

      final expectedDataPrefix = '0x095ea7b3';
      final expectedSpender =
          spenderAddress.replaceFirst('0x', '').padLeft(64, '0').toLowerCase();
      final expectedAmount = amount.toRadixString(16).padLeft(64, '0');
      expect(approval.transaction.data.toLowerCase(),
          '$expectedDataPrefix$expectedSpender$expectedAmount'.toLowerCase());
    });

    test('getApprovalMethod falls back to hardcoded spender if /price fails',
        () async {
      when(mockDio.get(any, queryParameters: anyNamed('queryParameters')))
          .thenThrow(DioException(requestOptions: RequestOptions(path: '')));

      final amount = BigInt.from(5000);
      final result = await provider.getApprovalMethod(
        chainId: chainId,
        tokenAddress: tokenAddress,
        ownerAddress: userAddress,
        amount: amount,
      );

      expect(result.isSuccess, true);
      final approval =
          (result as Success<ApprovalMethod>).value as StandardApproval;
      expect(
          approval.spenderAddress.toLowerCase(), spenderAddress.toLowerCase());
      expect(approval.amount, amount);
    });

    test('checkAllowance returns actual allowance from /price', () async {
      when(mockDio.get(argThat(contains('price')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {
                  'issues': {
                    'allowance': {
                      'actual': '500',
                    }
                  }
                },
                statusCode: 200,
              ));

      final result = await provider.checkAllowance(
        chainId: chainId,
        tokenAddress: tokenAddress,
        ownerAddress: userAddress,
      );

      expect(result.isSuccess, true);
      expect(result.valueOrNull, BigInt.from(500));
    });
  });
}
