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
import 'package:swap_aggregator/src/providers/thorchain_provider.dart';
import 'package:swap_aggregator/src/utils/result.dart';
import 'package:test/test.dart';

import 'thorchain_provider_test.mocks.dart';

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late ThorChainProvider provider;

  setUp(() {
    mockDio = MockDio();
    when(mockDio.options).thenReturn(BaseOptions());
    provider = ThorChainProvider(dio: mockDio);
  });

  group('ThorChainProvider', () {
    final userAddress = '0xUserAddress';
    final vaultAddress = '0xVaultAddress';

    test('buildTransactionV2 returns EvmTransaction for ETH', () async {
      final quote = SwapQuote(
        provider: 'ThorChain',
        params: SwapParams(
          fromChain: ChainId.ethereum,
          toChain: ChainId.bitcoin,
          fromToken: 'ETH',
          toToken: 'BTC',
          fromTokenAddress: '0xETH',
          toTokenAddress: 'native',
          amount: Decimal.one,
          userAddress: userAddress,
        ),
        inputAmount: Decimal.one,
        outputAmount: Decimal.parse('0.02'),
        minimumOutputAmount: Decimal.parse('0.019'),
        exchangeRate: Decimal.parse('0.02'),
        routes: [],
        gasEstimate: GasEstimate.zero(nativeSymbol: 'ETH'),
        priceImpact: 0.1,
        protocols: [],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {
          'vault': vaultAddress,
          'memo': 'SWAP:BTC.BTC:0xBTCRecipient',
        },
      );

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: userAddress,
      );

      expect(result.isSuccess, true);
      final tx = (result as Success<ChainTransaction>).value as EvmTransaction;
      expect(tx.to, vaultAddress);
      expect(tx.data, startsWith('0x535741503a')); // Hex for 'SWAP:'
      expect(tx.summary.toString(), 'Swap: 1 ETH → 0.02 BTC via ThorChain');
    });

    test('buildTransactionV2 returns UtxoTransaction for BTC', () async {
      final btcVault = 'bc1vault';
      final quote = SwapQuote(
        provider: 'ThorChain',
        params: SwapParams(
          fromChain: ChainId.bitcoin,
          toChain: ChainId.ethereum,
          fromToken: 'BTC',
          toToken: 'ETH',
          fromTokenAddress: 'native',
          toTokenAddress: '0xETH',
          amount: Decimal.parse('0.01'),
          userAddress: 'bc1user',
        ),
        inputAmount: Decimal.parse('0.01'),
        outputAmount: Decimal.parse('0.5'),
        minimumOutputAmount: Decimal.parse('0.49'),
        exchangeRate: Decimal.parse('50'),
        routes: [],
        gasEstimate: GasEstimate.zero(nativeSymbol: 'BTC'),
        priceImpact: 0.1,
        protocols: [],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {
          'inbound_address': btcVault,
          'memo': 'SWAP:ETH.ETH:0xETHRecipient',
        },
      );

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: 'bc1user',
      );

      expect(result.isSuccess, true);
      final tx = (result as Success<ChainTransaction>).value as UtxoTransaction;
      expect(tx.outputs.first.address, btcVault);
      expect(tx.chainId, ChainId.bitcoin);
      expect(tx.metadata['memo'], 'SWAP:ETH.ETH:0xETHRecipient');
    });

    test('getApprovalMethod returns NoApprovalNeeded for native ETH', () async {
      final result = await provider.getApprovalMethod(
        chainId: ChainId.ethereum,
        tokenAddress: '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        ownerAddress: userAddress,
        amount: BigInt.from(1000),
      );

      expect(result.isSuccess, true);
      expect(
          (result as Success<ApprovalMethod>).value is NoApprovalNeeded, true);
    });

    test('getApprovalMethod returns StandardApproval for ERC20', () async {
      final token = '0xToken';
      // Mock inbound addresses fetch
      when(mockDio.get(argThat(contains('inbound_addresses'))))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ''),
                data: [
                  {'chain': 'ETH', 'address': vaultAddress}
                ],
                statusCode: 200,
              ));

      final result = await provider.getApprovalMethod(
        chainId: ChainId.ethereum,
        tokenAddress: token,
        ownerAddress: userAddress,
        amount: BigInt.from(5000),
      );

      if (result.isFailure) {
        print('Error: ${result.errorOrNull}');
      }
      expect(result.isSuccess, true);
      final approval =
          (result as Success<ApprovalMethod>).value as StandardApproval;
      expect(approval.spenderAddress, vaultAddress);
      expect(approval.amount, BigInt.from(5000));
    });
  });
}
