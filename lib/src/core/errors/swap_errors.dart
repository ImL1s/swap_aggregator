/// Base class for all swap-related errors
sealed class SwapError implements Exception {
  final String message;
  final String? code;
  final dynamic details;

  const SwapError(this.message, {this.code, this.details});

  @override
  String toString() => 'SwapError: $message${code != null ? ' ($code)' : ''}';
}

/// Error when getting a quote fails
class QuoteError extends SwapError {
  const QuoteError(super.message, {super.code, super.details});
}

/// Error when building a transaction fails
class TransactionBuildError extends SwapError {
  const TransactionBuildError(super.message, {super.code, super.details});
}

/// Error when executing a swap fails
class SwapExecutionError extends SwapError {
  final String? txHash;

  const SwapExecutionError(
    super.message, {
    super.code,
    super.details,
    this.txHash,
  });
}

/// Error when token approval fails
class ApprovalError extends SwapError {
  const ApprovalError(super.message, {super.code, super.details});
}

/// Error when provider is not available
class ProviderUnavailableError extends SwapError {
  final String providerName;

  const ProviderUnavailableError(
    this.providerName, {
    String? message,
    super.code,
    super.details,
  }) : super(message ?? 'Provider $providerName is unavailable');
}

/// Error when chain is not supported
class UnsupportedChainError extends SwapError {
  final int chainId;

  const UnsupportedChainError(
    this.chainId, {
    String? message,
    super.code,
    super.details,
  }) : super(message ?? 'Chain $chainId is not supported');
}

/// Error when token is not supported
class UnsupportedTokenError extends SwapError {
  final String tokenAddress;

  const UnsupportedTokenError(
    this.tokenAddress, {
    String? message,
    super.code,
    super.details,
  }) : super(message ?? 'Token $tokenAddress is not supported');
}

/// Error when slippage is too high
class SlippageError extends SwapError {
  final double actualSlippage;
  final double maxSlippage;

  SlippageError({
    required this.actualSlippage,
    required this.maxSlippage,
    super.code,
    super.details,
  }) : super(
          'Slippage ${actualSlippage.toStringAsFixed(2)}% exceeds maximum ${maxSlippage.toStringAsFixed(2)}%',
        );
}

/// Error when there's insufficient liquidity
class InsufficientLiquidityError extends SwapError {
  const InsufficientLiquidityError({
    String message = 'Insufficient liquidity for this swap',
    super.code,
    super.details,
  }) : super(message);
}

/// Error when rate limit is exceeded
class RateLimitError extends SwapError {
  final Duration? retryAfter;

  const RateLimitError({
    String message = 'Rate limit exceeded',
    this.retryAfter,
    super.code,
    super.details,
  }) : super(message);
}

/// Error when quote has expired
class QuoteExpiredError extends SwapError {
  const QuoteExpiredError({
    String message = 'Quote has expired',
    super.code,
    super.details,
  }) : super(message);
}

/// Network-related errors
class NetworkError extends SwapError {
  final int? statusCode;

  const NetworkError(
    super.message, {
    this.statusCode,
    super.code,
    super.details,
  });
}

/// Error when API key is invalid or missing
class ApiKeyError extends SwapError {
  const ApiKeyError({
    String message = 'Invalid or missing API key',
    super.code,
    super.details,
  }) : super(message);
}
