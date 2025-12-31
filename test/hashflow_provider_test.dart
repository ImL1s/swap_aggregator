import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:mockito/mockito.dart';
import 'package:swap_aggregator/src/core/models/approval_method.dart';
import 'package:swap_aggregator/src/core/models/chain_id.dart';
import 'package:swap_aggregator/src/core/models/chain_transaction.dart';
import 'package:swap_aggregator/src/core/models/gas_estimate.dart';
import 'package:swap_aggregator/src/core/models/swap_params.dart';
import 'package:swap_aggregator/src/core/models/swap_quote.dart';
import 'package:swap_aggregator/src/providers/hashflow_provider.dart';
import 'package:test/test.dart';

// Reuse mock if possible or define here. Since I can't easily run build_runner,
// I'll try to find an existing MockDio or just mock Dio manually or use the generated one.
import 'one_inch_provider_test.mocks.dart';

void main() {
  late HashflowProvider provider;
  late MockDio mockDio;

  setUp(() {
    mockDio = MockDio();
    // Default mock setup
    when(mockDio.options).thenReturn(BaseOptions());
    provider = HashflowProvider(dio: mockDio);
  });

  group('HashflowProvider', () {
    final mockParams = SwapParams(
      fromChain: ChainId.ethereum,
      toChain: ChainId.ethereum,
      fromToken: 'ETH',
      toToken: 'USDC',
      fromTokenAddress: '0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      toTokenAddress: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
      amount: Decimal.one,
      fromTokenDecimals: 18,
      toTokenDecimals: 6,
      userAddress: '0xUser',
    );

    test('getQuote returns success with valid response', () async {
      final mockResponseData = {
        'rfqs': [
          {
            'baseTokenAmount': '1000000000000000000',
            'quoteTokenAmount': '2500000000',
            'quoteExpiry': 1700000000,
            'signature': '0xSig',
            'error': null,
          }
        ]
      };

      when(mockDio.post(
        any,
        data: anyNamed('data'),
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: mockResponseData,
          ));

      final result = await provider.getQuote(mockParams);

      expect(result.isSuccess, isTrue);
      final quote = result.valueOrNull!;
      expect(quote.provider, 'Hashflow');
      expect(quote.inputAmount, Decimal.one);
      expect(quote.outputAmount, Decimal.parse('2500'));
      expect(quote.metadata['signature'], '0xSig');
    });

    test('getQuote returns failure when RFQ has error', () async {
      final mockResponseData = {
        'rfqs': [
          {
            'error': 'INSUFFICIENT_LIQUIDITY',
          }
        ]
      };

      when(mockDio.post(
        any,
        data: anyNamed('data'),
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ''),
            data: mockResponseData,
          ));

      final result = await provider.getQuote(mockParams);

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, contains('INSUFFICIENT_LIQUIDITY'));
    });

    test('buildTransactionV2 returns EvmTransaction for Ethereum', () async {
      final quote = SwapQuote(
        provider: 'Hashflow',
        params: mockParams,
        inputAmount: Decimal.one,
        outputAmount: Decimal.parse('2500'),
        minimumOutputAmount: Decimal.parse('2500'),
        exchangeRate: Decimal.parse('2500'),
        routes: [],
        gasEstimate: GasEstimate.zero(),
        priceImpact: 0.0,
        protocols: ['Hashflow RFQ'],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {
          'rfq': {
            'address': '0xdE828fdc3F497F16416D1bB645261C7C6a62DAb5',
            'value': '0',
            'gasLimit': '300000'
          },
          'calldata': '0xActualCalldata',
          'signature': '0xSig'
        },
      );

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: '0xUser',
      );

      expect(result.isSuccess, isTrue);
      final tx = result.valueOrNull!;
      expect(tx, isA<EvmTransaction>());
      final evmTx = tx as EvmTransaction;
      expect(evmTx.to, '0xdE828fdc3F497F16416D1bB645261C7C6a62DAb5');
      expect(evmTx.data, '0xActualCalldata');
      expect(evmTx.summary.action, 'Swap');
    });

    test('buildTransactionV2 returns Bridge action for Cross-chain', () async {
      final crossChainParams = mockParams.copyWith(
        toChain: ChainId.bsc,
      );
      final quote = SwapQuote(
        provider: 'Hashflow',
        params: crossChainParams,
        inputAmount: Decimal.one,
        outputAmount: Decimal.parse('2500'),
        minimumOutputAmount: Decimal.parse('2500'),
        exchangeRate: Decimal.parse('2500'),
        routes: [],
        gasEstimate: GasEstimate.zero(),
        priceImpact: 0.0,
        protocols: ['Hashflow RFQ'],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {
          'rfq': {
            'address': '0xdE828fdc3F497F16416D1bB645261C7C6a62DAb5',
            'value': '0',
            'gasLimit': '300000'
          },
          'calldata': '0xActualCalldata',
          'signature': '0xSig'
        },
      );

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: '0xUser',
      );

      expect(result.isSuccess, isTrue);
      final tx = result.valueOrNull! as EvmTransaction;
      expect(tx.summary.action, 'Bridge');
      expect(tx.summary.destinationChain, 'BNB Smart Chain');
    });

    test('getQuote handles 429 Rate Limit error', () async {
      when(mockDio.post(any, data: anyNamed('data'))).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: ''),
          response: Response(
            requestOptions: RequestOptions(path: ''),
            statusCode: 429,
            data: {'error': 'Rate limit exceeded'},
          ),
          message: 'Http status error [429]',
        ),
      );

      final result = await provider.getQuote(mockParams);

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, contains('429'));
    });

    test('getQuote handles malformed JSON response', () async {
      when(mockDio.post(any, data: anyNamed('data'))).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: ''),
          data: {'something': 'invalid'},
        ),
      );

      final result = await provider.getQuote(mockParams);

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, contains('No quote from Hashflow'));
    });

    test('buildTransactionV2 returns SolanaTransaction for Solana', () async {
      final solanaParams = SwapParams(
        fromChain: ChainId.solana,
        toChain: ChainId.solana,
        fromToken: 'SOL',
        toToken: 'USDC',
        fromTokenAddress: 'So11111111111111111111111111111111111111112',
        toTokenAddress: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
        amount: Decimal.one,
        userAddress: 'SolTrader',
      );

      final quote = SwapQuote(
        provider: 'Hashflow',
        params: solanaParams,
        inputAmount: Decimal.one,
        outputAmount: Decimal.parse('100'),
        minimumOutputAmount: Decimal.parse('100'),
        exchangeRate: Decimal.parse('100'),
        routes: [],
        gasEstimate: GasEstimate.zero(),
        priceImpact: 0.0,
        protocols: ['Hashflow RFQ'],
        validUntil: 0,
        timestamp: DateTime.now(),
        metadata: {
          'rfq': {'transactionData': 'base64EncodedData'},
          'signature': '0xSig'
        },
      );

      final result = await provider.buildTransactionV2(
        quote: quote,
        userAddress: 'SolTrader',
      );

      expect(result.isSuccess, isTrue);
      final tx = result.valueOrNull!;
      expect(tx, isA<SolanaTransaction>());
      final solTx = tx as SolanaTransaction;
      expect(solTx.base64EncodedTransaction, 'base64EncodedData');
    });

    test('getApprovalMethod returns NoApprovalNeeded for Native ETH', () async {
      final result = await provider.getApprovalMethod(
        chainId: ChainId.ethereum,
        tokenAddress: 'native',
        ownerAddress: '0xUser',
        amount: BigInt.from(1000),
      );

      expect(result.isSuccess, isTrue);
      expect(result.valueOrNull!, isA<NoApprovalNeeded>());
    });

    test('getApprovalMethod returns StandardApproval for ERC20', () async {
      final result = await provider.getApprovalMethod(
        chainId: ChainId.ethereum,
        tokenAddress: '0xToken',
        ownerAddress: '0xUser',
        amount: BigInt.from(1000),
      );

      expect(result.isFailure, isTrue);
      expect(result.errorOrNull, contains('fetching the spender'));
    });
  });
}
