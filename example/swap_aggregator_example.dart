import 'package:decimal/decimal.dart';
import 'package:swap_aggregator/swap_aggregator.dart';

void main() async {
  print('Initializing Swap Aggregator...');

  // 1. Initialize Providers
  // In a real app, you would inject API keys here
  final providers = [
    ParaSwapProvider(),
    // OneInchProvider(apiKey: 'YOUR_KEY'),
    // UniswapProvider(apiKey: 'YOUR_KEY'),
    // ZeroXProvider(apiKey: 'YOUR_KEY'),
    // OpenOceanProvider(),
  ];

  final aggregator = SwapAggregatorService(providers: providers);

  // 2. Define Swap Parameters
  // Example: Swap 1 ETH for USDC on Ethereum Mainnet
  final params = SwapParams(
    fromChain: ChainId.ethereum,
    toChain: ChainId.ethereum,
    fromToken: 'ETH',
    toToken: 'USDC',
    fromTokenAddress: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE', // ETH
    toTokenAddress: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', // USDC
    amount: Decimal.parse('1.0'),
    fromTokenDecimals: 18,
    toTokenDecimals: 6,
    userAddress:
        '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045', // Vitalik's address (example)
    slippage: 0.5, // 0.5%
  );

  print('Fetching quotes for 1 ETH -> USDC...');

  try {
    // 3. Get Quotes
    final result = await aggregator.getBestQuote(params);

    if (result.isSuccess) {
      final quote = result.valueOrNull!;
      print('\nBest Quote Found:');
      print('Provider: ${quote.provider}');
      print('Rate: 1 ETH = ${quote.exchangeRate} USDC');
      print('Output: ${quote.outputAmount} USDC');
      print('Gas: ${quote.gasEstimate.estimatedCostInToken} ETH');

      // 4. Build Transaction
      print('\nBuilding transaction...');
      final txResult = await aggregator.buildTransaction(
        quote: quote,
        userAddress: params.userAddress,
      );

      if (txResult.isSuccess) {
        final tx = txResult.valueOrNull!;
        print('Transaction ready to sign:');
        print('To: ${tx.to}');
        print('Value: ${tx.value}');
        print('Data length: ${tx.data.length} bytes');
      } else {
        print('Failed to build transaction: ${txResult.errorOrNull}');
      }
    } else {
      print('\nNo quotes found. Error: ${result.errorOrNull}');
    }
  } catch (e) {
    print('Unexpected error: $e');
  }
}
