import 'package:equatable/equatable.dart';

/// Represents a blockchain network identifier
///
/// This enum provides a chain-agnostic way to identify networks
/// without coupling to any specific wallet implementation.
enum ChainId {
  // EVM Chains
  ethereum(1, 'Ethereum', 'ETH', 18),
  bsc(56, 'BNB Smart Chain', 'BNB', 18),
  polygon(137, 'Polygon', 'MATIC', 18),
  avalanche(43114, 'Avalanche', 'AVAX', 18),
  arbitrum(42161, 'Arbitrum', 'ETH', 18),
  optimism(10, 'Optimism', 'ETH', 18),
  base(8453, 'Base', 'ETH', 18),
  fantom(250, 'Fantom', 'FTM', 18),
  gnosis(100, 'Gnosis', 'xDAI', 18),
  zksync(324, 'zkSync Era', 'ETH', 18),
  linea(59144, 'Linea', 'ETH', 18),
  scroll(534352, 'Scroll', 'ETH', 18),
  mantle(5000, 'Mantle', 'MNT', 18),
  blast(81457, 'Blast', 'ETH', 18),

  // Non-EVM Chains (for cross-chain providers like Rango)
  legacy_solana(7565164, 'Solana Legacy', 'SOL', 9,
      isEvm: false), // DeBridge specific ID?
  solana(0, 'Solana', 'SOL', 9, isEvm: false),
  aurora(1313161554, 'Aurora', 'ETH', 18),
  metis(1088, 'Metis', 'METIS', 18),
  moonbeam(1284, 'Moonbeam', 'GLMR', 18),
  moonriver(1285, 'Moonriver', 'MOVR', 18),
  celo(42220, 'Celo', 'CELO', 18),
  cronos(25, 'Cronos', 'CRO', 18),
  cosmos(0, 'Cosmos Hub', 'ATOM', 6, isEvm: false),
  osmosis(0, 'Osmosis', 'OSMO', 6, isEvm: false),
  ton(0, 'TON', 'TON', 9, isEvm: false),
  sui(0, 'Sui', 'SUI', 9, isEvm: false),
  aptos(0, 'Aptos', 'APT', 8, isEvm: false),
  near(0, 'NEAR', 'NEAR', 24, isEvm: false),
  tron(0, 'TRON', 'TRX', 6, isEvm: false),
  bitcoin(0, 'Bitcoin', 'BTC', 8, isEvm: false);

  final int id;
  final String name;
  final String nativeSymbol;
  final int nativeDecimals;
  final bool isEvm;

  const ChainId(this.id, this.name, this.nativeSymbol, this.nativeDecimals,
      {this.isEvm = true});

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
