/// Swap Aggregator - A modular DEX aggregator for multi-chain token swaps
///
/// This library provides a unified interface for interacting with multiple
/// DEX aggregators including 1inch, ParaSwap, Uniswap, 0x, OpenOcean, and Rango.
///
/// ## Features
/// - 🔌 Plug-and-play provider architecture
/// - 🔗 Cross-chain swap support (via Rango)
/// - 📊 Quote comparison and best route selection
/// - 🛡️ MEV protection ready
/// - 🧩 Pure Dart - no Flutter dependencies
///
/// ## Usage
///
/// ```dart
/// import 'package:swap_aggregator/swap_aggregator.dart';
///
/// final aggregator = SwapAggregatorService(
///   providers: [
///     OneInchProvider(apiKey: 'your-api-key'),
///     ParaSwapProvider(), // No API key required
///   ],
/// );
///
/// final quotes = await aggregator.getQuotes(SwapParams(
///   fromChain: ChainId.ethereum,
///   toChain: ChainId.ethereum,
///   fromToken: 'ETH',
///   toToken: 'USDC',
///   fromTokenAddress: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE',
///   toTokenAddress: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
///   amount: Decimal.parse('1.0'),
///   userAddress: '0x...',
/// ));
/// ```
library swap_aggregator;

// Core interfaces
export 'src/core/swap_provider_interface.dart';
export 'src/core/swap_aggregator_interface.dart';

// Models
export 'src/core/models/chain_id.dart';
export 'src/core/models/swap_params.dart';
export 'src/core/models/swap_quote.dart';
export 'src/core/models/swap_transaction.dart';
export 'src/core/models/swap_status.dart';
export 'src/core/models/gas_estimate.dart';
export 'src/core/models/token.dart';
export 'src/core/models/chain_transaction.dart';
export 'src/core/models/approval_method.dart';

// Errors
export 'src/core/errors/swap_errors.dart';

// Providers
export 'src/providers/one_inch_provider.dart';
export 'src/providers/paraswap_provider.dart';
export 'src/providers/uniswap_provider.dart';
export 'src/providers/zerox_provider.dart';
export 'src/providers/openocean_provider.dart';
export 'src/providers/rango_provider.dart';
export 'src/providers/jupiter_provider.dart';
export 'src/providers/kyberswap_provider.dart';
export 'src/providers/lifi_provider.dart';
export 'src/providers/thorchain_provider.dart';
export 'src/providers/odos_provider.dart';
export 'src/providers/debridge_provider.dart';
export 'src/providers/socket_provider.dart';
export 'src/providers/rubic_provider.dart';
export 'src/providers/squid_provider.dart';
export 'src/providers/hashflow_provider.dart';
export 'src/providers/cow_provider.dart';
export 'src/providers/enso_provider.dart';
export 'src/providers/okx_provider.dart';
export 'src/providers/bebop_provider.dart';
export 'src/providers/across_provider.dart';
export 'src/providers/symbiosis_provider.dart';
export 'src/providers/woofi_provider.dart';

// Aggregator Service
export 'src/aggregator/swap_aggregator_service.dart';
export 'src/aggregator/quote_comparator.dart';

// Utils
export 'src/utils/result.dart';
