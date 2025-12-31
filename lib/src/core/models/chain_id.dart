import 'package:equatable/equatable.dart';

/// Represents a blockchain network identifier
///
/// This enum provides a chain-agnostic way to identify networks
/// without coupling to any specific wallet implementation.
enum ChainId {
  // EVM Chains
  ethereum(1, 'Ethereum', 'ETH'),
  bsc(56, 'BNB Smart Chain', 'BNB'),
  polygon(137, 'Polygon', 'MATIC'),
  avalanche(43114, 'Avalanche', 'AVAX'),
  arbitrum(42161, 'Arbitrum', 'ETH'),
  optimism(10, 'Optimism', 'ETH'),
  base(8453, 'Base', 'ETH'),
  fantom(250, 'Fantom', 'FTM'),
  gnosis(100, 'Gnosis', 'xDAI'),
  zksync(324, 'zkSync Era', 'ETH'),
  linea(59144, 'Linea', 'ETH'),
  scroll(534352, 'Scroll', 'ETH'),
  mantle(5000, 'Mantle', 'MNT'),
  blast(81457, 'Blast', 'ETH'),

  // Non-EVM Chains (for cross-chain providers like Rango)
  legacy_solana(7565164, 'Solana Legacy', 'SOL',
      isEvm: false), // DeBridge specific ID?
  solana(0, 'Solana', 'SOL', isEvm: false),
  aurora(1313161554, 'Aurora', 'ETH'),
  metis(1088, 'Metis', 'METIS'),
  moonbeam(1284, 'Moonbeam', 'GLMR'),
  moonriver(1285, 'Moonriver', 'MOVR'),
  celo(42220, 'Celo', 'CELO'),
  cronos(25, 'Cronos', 'CRO'),
  cosmos(0, 'Cosmos Hub', 'ATOM', isEvm: false),
  osmosis(0, 'Osmosis', 'OSMO', isEvm: false),
  ton(0, 'TON', 'TON', isEvm: false),
  sui(0, 'Sui', 'SUI', isEvm: false),
  aptos(0, 'Aptos', 'APT', isEvm: false),
  near(0, 'NEAR', 'NEAR', isEvm: false),
  tron(0, 'TRON', 'TRX', isEvm: false),
  bitcoin(0, 'Bitcoin', 'BTC', isEvm: false);

  final int id;
  final String name;
  final String nativeSymbol;
  final bool isEvm;

  const ChainId(this.id, this.name, this.nativeSymbol, {this.isEvm = true});

  /// Get ChainId from EVM chain ID number
  static ChainId? fromId(int id) {
    try {
      return ChainId.values.firstWhere((c) => c.id == id && c.isEvm);
    } catch (_) {
      return null;
    }
  }

  /// Get ChainId from name
  static ChainId? fromName(String name) {
    final lowerName = name.toLowerCase();
    try {
      return ChainId.values.firstWhere(
        (c) => c.name.toLowerCase() == lowerName,
      );
    } catch (_) {
      return null;
    }
  }

  /// Native token address (common pattern for EVM chains)
  String get nativeTokenAddress => '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE';

  /// Check if this is a testnet
  bool get isTestnet => false; // Can be extended for testnet support
}

/// Chain information for display purposes
class ChainInfo extends Equatable {
  final ChainId chainId;
  final String? logoUrl;
  final String? explorerUrl;
  final String? rpcUrl;

  const ChainInfo({
    required this.chainId,
    this.logoUrl,
    this.explorerUrl,
    this.rpcUrl,
  });

  @override
  List<Object?> get props => [chainId, logoUrl, explorerUrl, rpcUrl];
}
