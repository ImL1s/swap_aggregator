import 'package:equatable/equatable.dart';

import 'chain_id.dart';

/// Token information
class Token extends Equatable {
  /// Token symbol (e.g., 'ETH', 'USDC')
  final String symbol;

  /// Token name (e.g., 'Ethereum', 'USD Coin')
  final String name;

  /// Contract address (native token uses special address)
  final String address;

  /// Token decimals
  final int decimals;

  /// Chain this token is on
  final ChainId chainId;

  /// Logo URL (optional)
  final String? logoUrl;

  /// Whether this is the native token
  final bool isNative;

  /// Coingecko ID for price lookup (optional)
  final String? coingeckoId;

  /// Additional metadata
  final Map<String, dynamic> metadata;

  const Token({
    required this.symbol,
    required this.name,
    required this.address,
    required this.decimals,
    required this.chainId,
    this.logoUrl,
    this.isNative = false,
    this.coingeckoId,
    this.metadata = const {},
  });

  /// Create native token for a chain
  factory Token.native(ChainId chainId) {
    return Token(
      symbol: chainId.nativeSymbol,
      name: chainId.name,
      address: chainId.nativeTokenAddress,
      decimals: chainId.nativeDecimals,
      chainId: chainId,
      isNative: true,
    );
  }

  /// Create from JSON (common API response format)
  factory Token.fromJson(Map<String, dynamic> json, ChainId chainId) {
    return Token(
      symbol: json['symbol'] as String? ?? '',
      name: json['name'] as String? ?? json['symbol'] as String? ?? '',
      address: json['address'] as String? ?? '',
      decimals: json['decimals'] as int? ?? 18,
      chainId: chainId,
      logoUrl: json['logoURI'] as String? ?? json['logoUrl'] as String?,
      isNative: json['isNative'] as bool? ?? false,
      coingeckoId: json['coingeckoId'] as String?,
      metadata: json,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'symbol': symbol,
      'name': name,
      'address': address,
      'decimals': decimals,
      'chainId': chainId.id,
      'logoUrl': logoUrl,
      'isNative': isNative,
      'coingeckoId': coingeckoId,
    };
  }

  @override
  List<Object?> get props => [symbol, address, decimals, chainId, isNative];

  @override
  String toString() => 'Token($symbol on ${chainId.name})';
}

/// Token pair for swap
class TokenPair extends Equatable {
  final Token fromToken;
  final Token toToken;

  const TokenPair({required this.fromToken, required this.toToken});

  /// Check if this is a cross-chain pair
  bool get isCrossChain => fromToken.chainId != toToken.chainId;

  @override
  List<Object?> get props => [fromToken, toToken];
}
