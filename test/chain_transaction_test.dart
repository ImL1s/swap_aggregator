import 'package:decimal/decimal.dart';
import 'package:test/test.dart';
import 'package:swap_aggregator/swap_aggregator.dart';

void main() {
  group('ChainTransaction Sealed Classes', () {
    group('EvmTransaction', () {
      test('creates with required fields', () {
        final tx = EvmTransaction(
          from: '0x1234567890abcdef1234567890abcdef12345678',
          to: '0xabcdef1234567890abcdef1234567890abcdef12',
          data: '0x',
          value: BigInt.from(1000000000000000000), // 1 ETH
          gasLimit: BigInt.from(21000),
          gasPrice: BigInt.from(20000000000), // 20 Gwei
          chainId: ChainId.ethereum,
          summary: TransactionSummary(
            action: 'Swap',
            fromAsset: 'ETH',
            toAsset: 'USDC',
            inputAmount: Decimal.one,
            expectedOutput: Decimal.parse('2000'),
            protocol: '1inch',
          ),
        );

        expect(tx.from, '0x1234567890abcdef1234567890abcdef12345678');
        expect(tx.to, '0xabcdef1234567890abcdef1234567890abcdef12');
        expect(tx.value, BigInt.from(1000000000000000000));
        expect(tx.chainId, ChainId.ethereum);
        expect(tx.isEip1559, false);
      });

      test('supports EIP-1559 gas pricing', () {
        final tx = EvmTransaction(
          from: '0x123',
          to: '0x456',
          data: '0x',
          value: BigInt.zero,
          gasLimit: BigInt.from(100000),
          gasPrice: BigInt.zero,
          maxFeePerGas: BigInt.from(30000000000),
          maxPriorityFeePerGas: BigInt.from(2000000000),
          chainId: ChainId.ethereum,
          summary: TransactionSummary(
            action: 'Swap',
            fromAsset: 'USDC',
            toAsset: 'ETH',
            inputAmount: Decimal.parse('1000'),
            expectedOutput: Decimal.parse('0.5'),
            protocol: 'Uniswap',
          ),
        );

        expect(tx.isEip1559, true);
        expect(tx.maxFeePerGas, BigInt.from(30000000000));
      });

      test('converts to JSON correctly', () {
        final tx = EvmTransaction(
          from: '0xabc',
          to: '0xdef',
          data: '0x123456',
          value: BigInt.from(10),
          gasLimit: BigInt.from(21000),
          gasPrice: BigInt.from(1000000000),
          chainId: ChainId.ethereum,
          summary: TransactionSummary(
            action: 'Send',
            fromAsset: 'ETH',
            toAsset: 'ETH',
            inputAmount: Decimal.parse('0.00000001'),
            expectedOutput: Decimal.parse('0.00000001'),
            protocol: 'Native',
          ),
        );

        final json = tx.toJson();
        expect(json['from'], '0xabc');
        expect(json['to'], '0xdef');
        expect(json['data'], '0x123456');
        expect(json['value'], '0xa'); // 10 in hex
        expect(json['gas'], '0x5208'); // 21000 in hex
      });
    });

    group('SolanaTransaction', () {
      test('creates with base64 encoded transaction', () {
        final tx = SolanaTransaction(
          base64EncodedTransaction: 'SGVsbG8gV29ybGQ=',
          requiredSigners: ['9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM'],
          chainId: ChainId.solana,
          summary: TransactionSummary(
            action: 'Swap',
            fromAsset: 'SOL',
            toAsset: 'USDC',
            inputAmount: Decimal.one,
            expectedOutput: Decimal.parse('100'),
            protocol: 'Jupiter',
          ),
        );

        expect(tx.base64EncodedTransaction, 'SGVsbG8gV29ybGQ=');
        expect(tx.requiredSigners.length, 1);
        expect(tx.chainId, ChainId.solana);
      });

      test('supports compute unit pricing', () {
        final tx = SolanaTransaction(
          base64EncodedTransaction: 'dGVzdA==',
          computeUnitLimit: 200000,
          computeUnitPrice: 1000,
          chainId: ChainId.solana,
          summary: TransactionSummary(
            action: 'Swap',
            fromAsset: 'SOL',
            toAsset: 'RAY',
            inputAmount: Decimal.parse('10'),
            expectedOutput: Decimal.parse('500'),
            protocol: 'Jupiter',
          ),
        );

        expect(tx.computeUnitLimit, 200000);
        expect(tx.computeUnitPrice, 1000);
      });
    });

    group('UtxoTransaction', () {
      test('creates with inputs and outputs', () {
        final tx = UtxoTransaction(
          inputs: [
            UtxoInput(
              txHash: 'abc123',
              vout: 0,
              value: BigInt.from(100000),
            ),
          ],
          outputs: [
            UtxoOutput(
              address: 'bc1q...',
              value: BigInt.from(90000),
            ),
          ],
          feeRateSatPerVb: 10,
          chainId: ChainId.bitcoin,
          summary: TransactionSummary(
            action: 'Bridge',
            fromAsset: 'BTC',
            toAsset: 'WBTC',
            inputAmount: Decimal.parse('0.001'),
            expectedOutput: Decimal.parse('0.00099'),
            destinationChain: 'Ethereum',
            protocol: 'ThorChain',
          ),
        );

        expect(tx.inputs.length, 1);
        expect(tx.outputs.length, 1);
        expect(tx.feeRateSatPerVb, 10);
        expect(tx.totalFee, BigInt.from(10000));
      });
    });

    group('CosmosTransaction', () {
      test('creates with messages and fee', () {
        final tx = CosmosTransaction(
          messages: [
            CosmosMessage(
              typeUrl: '/cosmos.bank.v1beta1.MsgSend',
              value: {
                'from_address': 'cosmos1...',
                'to_address': 'cosmos2...',
                'amount': [
                  {'denom': 'uatom', 'amount': '1000000'}
                ],
              },
            ),
          ],
          fee: CosmosFee(
            amount: [CosmosCoin(denom: 'uatom', amount: BigInt.from(5000))],
            gasLimit: BigInt.from(200000),
          ),
          memo: 'Test transfer',
          chainId: ChainId.cosmos,
          summary: TransactionSummary(
            action: 'Send',
            fromAsset: 'ATOM',
            toAsset: 'ATOM',
            inputAmount: Decimal.one,
            expectedOutput: Decimal.one,
            protocol: 'Cosmos',
          ),
        );

        expect(tx.messages.length, 1);
        expect(tx.messages.first.typeUrl, '/cosmos.bank.v1beta1.MsgSend');
        expect(tx.memo, 'Test transfer');
        expect(tx.fee.gasLimit, BigInt.from(200000));
      });
    });

    group('Pattern Matching', () {
      test('can match on ChainTransaction subtypes', () {
        final ChainTransaction evmTx = EvmTransaction(
          from: '0x1',
          to: '0x2',
          data: '0x',
          value: BigInt.zero,
          gasLimit: BigInt.from(21000),
          gasPrice: BigInt.zero,
          chainId: ChainId.ethereum,
          summary: TransactionSummary(
            action: 'Test',
            fromAsset: 'ETH',
            toAsset: 'ETH',
            inputAmount: Decimal.zero,
            expectedOutput: Decimal.zero,
            protocol: 'Test',
          ),
        );

        final result = switch (evmTx) {
          EvmTransaction tx => 'EVM: ${tx.chainId.name}',
          SolanaTransaction tx =>
            'Solana: ${tx.requiredSigners.length} signers',
          UtxoTransaction tx => 'UTXO: ${tx.inputs.length} inputs',
          CosmosTransaction tx => 'Cosmos: ${tx.messages.length} messages',
        };

        expect(result, 'EVM: Ethereum');
      });
    });
  });

  group('ApprovalMethod Sealed Classes', () {
    group('StandardApproval', () {
      test('detects unlimited approval', () {
        final maxUint256 = BigInt.parse(
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
          radix: 16,
        );

        final approval = StandardApproval(
          transaction: EvmTransaction(
            from: '0x1',
            to: '0x2',
            data: '0x',
            value: BigInt.zero,
            gasLimit: BigInt.from(50000),
            gasPrice: BigInt.zero,
            chainId: ChainId.ethereum,
            summary: TransactionSummary(
              action: 'Approve',
              fromAsset: 'USDC',
              toAsset: 'USDC',
              inputAmount: Decimal.zero,
              expectedOutput: Decimal.zero,
              protocol: '1inch',
            ),
          ),
          tokenAddress: '0xtoken',
          spenderAddress: '0xspender',
          amount: maxUint256,
        );

        expect(approval.isUnlimited, true);
      });

      test('detects limited approval', () {
        final approval = StandardApproval(
          transaction: EvmTransaction(
            from: '0x1',
            to: '0x2',
            data: '0x',
            value: BigInt.zero,
            gasLimit: BigInt.from(50000),
            gasPrice: BigInt.zero,
            chainId: ChainId.ethereum,
            summary: TransactionSummary(
              action: 'Approve',
              fromAsset: 'USDC',
              toAsset: 'USDC',
              inputAmount: Decimal.zero,
              expectedOutput: Decimal.zero,
              protocol: '1inch',
            ),
          ),
          tokenAddress: '0xtoken',
          spenderAddress: '0xspender',
          amount: BigInt.from(1000000),
        );

        expect(approval.isUnlimited, false);
      });
    });

    group('PermitSignature', () {
      test('creates with EIP-2612 fields', () {
        final typedData = Eip712TypedData(
          domain: Eip712Domain(
            name: 'Token',
            version: '1',
            chainId: 1,
            verifyingContract: '0xToken',
          ),
          types: {
            'Permit': [
              Eip712Type(name: 'owner', type: 'address'),
              Eip712Type(name: 'spender', type: 'address'),
              Eip712Type(name: 'value', type: 'uint256'),
              Eip712Type(name: 'nonce', type: 'uint256'),
              Eip712Type(name: 'deadline', type: 'uint256'),
            ],
          },
          primaryType: 'Permit',
          message: {
            'owner': '0xOwner',
            'spender': '0xSpender',
            'value': '1000',
            'nonce': '0',
            'deadline': '1234567890',
          },
        );

        final permit = PermitSignature(
          typedData: typedData,
          tokenAddress: '0xToken',
          spenderAddress: '0xSpender',
          amount: BigInt.from(1000),
          validity: Duration(minutes: 20),
          deadline: 1234567890,
          nonce: 0,
        );

        expect(permit.tokenAddress, '0xToken');
        expect(permit.nonce, 0);
        expect(permit.amount, BigInt.from(1000));
      });
    });

    group('Permit2Signature', () {
      test('creates with Permit2 fields', () {
        final typedData = Eip712TypedData(
          domain: Eip712Domain(
            name: 'Permit2',
            version: '1',
            chainId: 1,
            verifyingContract: '0xPermit2',
          ),
          types: {},
          primaryType: 'PermitTransferFrom',
          message: {},
        );

        final permit2 = Permit2Signature(
          typedData: typedData,
          permit2ContractAddress: '0xPermit2',
          tokenAddress: '0xToken',
          spenderAddress: '0xSpender',
          amount: BigInt.from(500),
          deadline: 1234567890,
          nonce: BigInt.one,
          chainId: ChainId.ethereum,
        );

        expect(permit2.permit2ContractAddress, '0xPermit2');
        expect(permit2.amount, BigInt.from(500));
        expect(permit2.chainId, ChainId.ethereum);
      });
    });

    group('Pattern Matching', () {
      test('can match on ApprovalMethod subtypes', () {
        final ApprovalMethod method = NoApprovalNeeded(
          reason: 'Native token',
        );

        final result = switch (method) {
          StandardApproval a => 'Standard: ${a.tokenAddress}',
          PermitSignature p => 'Permit: nonce ${p.nonce}',
          Permit2Signature p2 => 'Permit2: ${p2.permit2ContractAddress}',
          NoApprovalNeeded n => 'No approval: ${n.reason}',
        };

        expect(result, 'No approval: Native token');
      });
    });
  });

  group('TransactionSummary', () {
    test('formats toString correctly', () {
      final summary = TransactionSummary(
        action: 'Swap',
        fromAsset: 'ETH',
        toAsset: 'USDC',
        inputAmount: Decimal.one,
        expectedOutput: Decimal.parse('2000'),
        protocol: '1inch',
      );

      expect(summary.toString(), 'Swap: 1 ETH → 2000 USDC via 1inch');
    });

    test('includes destination chain for cross-chain', () {
      final summary = TransactionSummary(
        action: 'Bridge',
        fromAsset: 'ETH',
        toAsset: 'ETH',
        inputAmount: Decimal.one,
        expectedOutput: Decimal.parse('0.999'),
        destinationChain: 'Arbitrum',
        protocol: 'Across',
      );

      expect(summary.destinationChain, 'Arbitrum');
    });
  });
}
