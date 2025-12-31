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
import 'package:swap_aggregator/src/providers/paraswap_provider.dart';
import 'package:swap_aggregator/src/utils/result.dart';
import 'package:test/test.dart';

import 'paraswap_provider_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late ParaSwapProvider provider;

  setUp(() {
    mockDio = MockDio();
    when(mockDio.options).thenReturn(BaseOptions());
    provider = ParaSwapProvider(dio: mockDio);
  });

  group('ParaSwapProvider', () {
    final chainId = ChainId.ethereum;
    final tokenAddress = '0x1111111111111111111111111111111111111111';
    final userAddress = '0xUserAddress';
    final spenderAddress = '0xSpenderAddress';

    test('buildTransactionV2 returns EvmTransaction', () async {
      final quote = SwapQuote(
        provider: 'ParaSwap',
        params: SwapParams(
          fromChain: ChainId.ethereum,
          toChain: ChainId.ethereum,
          fromToken: 'ETH',
          toToken: 'USDC',
          fromTokenAddress: '0xETH',
          toTokenAddress: '0xUSDC',
          amount: Decimal.one,
          userAddress: userAddress,
          slippage: 0.5,
          fromTokenDecimals: 18,
          toTokenDecimals: 6,
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
          'priceRoute': {
            'srcAmount': '1000000000000000000',
            'destAmount': '2000000000'
          }
        },
      );

      final txResponse = {
        'from': userAddress,
        'to': '0xRouter',
        'data': '0x123456',
        'value': '1000000000000000000',
        'gas': '500000',
        'gasPrice': '5000000000',
      };

      when(mockDio.post(
        any,
        data: anyNamed('data'),
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: txResponse,
            statusCode: 200,
          ));

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: userAddress,
      );

      expect(result.isSuccess, true);
      final tx = (result as Success<ChainTransaction>).value;
      expect(tx is EvmTransaction, true);
      final evmTx = tx as EvmTransaction;
      expect(evmTx.to, '0xRouter');
      expect(evmTx.data, '0x123456');
      expect(evmTx.summary.toString(), 'Swap: 1 ETH → 2000 USDC via ParaSwap');
    });

    test('getApprovalMethod returns NoApprovalNeeded when allowance sufficient',
        () async {
      when(mockDio.get(argThat(contains('adapters')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {'tokenTransferProxy': spenderAddress},
                statusCode: 200,
              ));

      when(mockDio.get(argThat(contains('allowances')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {'allowance': '1000000000000000000000'},
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
        'getApprovalMethod returns StandardApproval with encoded data when allowance insufficient',
        () async {
      when(mockDio.get(argThat(contains('adapters')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {'tokenTransferProxy': spenderAddress},
                statusCode: 200,
              ));

      when(mockDio.get(argThat(contains('allowances')),
              queryParameters: anyNamed('queryParameters')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: {'allowance': '0'},
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

      // Verify manual encoding
      // 0x095ea7b3 + 64 chars spender + 64 chars amount
      final expectedDataPrefix = '0x095ea7b3';
      final expectedSpender =
          spenderAddress.replaceFirst('0x', '').padLeft(64, '0');
      final expectedAmount = amount.toRadixString(16).padLeft(64, '0');

      expect(approval.transaction.data,
          '$expectedDataPrefix$expectedSpender$expectedAmount');
    });
  });
}
