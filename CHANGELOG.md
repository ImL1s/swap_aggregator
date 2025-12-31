# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-01-01

### Added
- Initial release of the Swap Aggregator SDK.
- Support for 23+ DEX aggregators including:
  - **EVM**: 1inch, ParaSwap, 0x, OpenOcean, Uniswap, KyberSwap, Odos, Enso, Bebop
  - **Cross-chain**: Rango, Socket, LI.FI, deBridge, Squid, Symbiosis, WOOFi
  - **RFQ/Intent**: Hashflow, CoW Protocol
  - **Solana**: Jupiter
  - **Bitcoin**: THORChain
- `SwapProviderInterface` for easy custom provider implementation.
- `SwapAggregatorService` with dynamic provider registration.
- Multi-chain transaction support via `ChainTransaction` sealed classes.
- Comprehensive approval handling (ERC20, Permit, Permit2).
- Quote comparison and sorting utilities.
