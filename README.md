# PrimeHash contracts

**Liquidity is Hashpower.** A Uniswap v4 hook and a PositionManager subscriber that turn full-range ETH/PRIME liquidity positions into mining rigs.

- Website: https://primehash.org
- Agent-readable summary: https://primehash.org/llms.txt
- X: https://x.com/primehashorg · Telegram: https://t.me/primehashorg

## How it works

- **Swap fee.** `PrimeHashHook` charges a fixed 3% fee in ETH on every swap of the ETH/PRIME pool (via `beforeSwapReturnDelta` / `afterSwapReturnDelta`). Half goes to miners, half to the protocol treasury. LPs keep the normal 0.30% LP fee on top.
- **Mining.** A full-range position NFT subscribed to `MiningEngine` (a v4 PositionManager subscriber) is a rig. Its hashpower is its liquidity. Rigs share:
  - **PRIME emission:** 5 PRIME per block, halving every 2,079,000 blocks, 21,000,000 max supply;
  - **ETH:** the miners' half of the hook fee, streamed over 7,200 blocks (~1 day) so just-in-time liquidity cannot capture it.
- **Gas.** The hook forwards miner ETH to the engine at most every 25 blocks, so a swap stays cheap.
- **Ownership.** Rewards belong to the position NFT. Subscriber callbacks never revert after subscription, so they cannot block a withdrawal.
- **Entry with ETH only.** `MiningZap` takes plain ETH, swaps the right share for PRIME, mints the position to the caller and refunds the dust. Then the owner subscribes the NFT to the engine.
- **Immutable.** No owner, no admin functions, no upgradeability. Fees and emission are constants.
- **Plug & Play rigs.** `RigShop` sells ready-built full-range positions made by the treasury, at a fixed ETH price set on-chain at build time (value + 20%). What a rig mines while on display is burned at sale (PRIME) or sent to the treasury (ETH); the buyer gets the bare position NFT and subscribes it. The shop is the only contract with a role: the treasury can build and delist rigs, nothing else.

| Contract | Role |
|---|---|
| `src/PrimeHashHook.sol` | 3% ETH fee on every swap (1.5% miners, 1.5% treasury) |
| `src/MiningEngine.sol` | PositionManager subscriber: rigs earn PRIME and streamed ETH |
| `src/PrimeToken.sol` | ERC-20 PRIME, 21M cap, only the MiningEngine can mint |
| `src/GenesisReserve.sol` | Holds the 210,000 PRIME genesis, creates the pool, owns the launch liquidity forever |
| `src/MiningZap.sol` | One-transaction entry with ETH only (swap + mint), optional on-chain referrer |
| `src/RigShop.sol` | Plug & Play rigs: treasury-built positions sold for ETH at build value + 20% |

## Deployments: Ethereum mainnet

All are verified on Etherscan and Sourcify. Deploy block: 26497099.

| Contract | Address |
|---|---|
| PRIME | [`0xAafa34D12F0CAe4A8395916807b1433D63f27612`](https://etherscan.io/address/0xAafa34D12F0CAe4A8395916807b1433D63f27612#code) |
| MiningEngine | [`0xDb5658c775D77c4792C5A8A944F674bF00752E89`](https://etherscan.io/address/0xDb5658c775D77c4792C5A8A944F674bF00752E89#code) |
| PrimeHashHook | [`0x22Fc32f6AbF32EC820207dD6751a9334CeE320cc`](https://etherscan.io/address/0x22Fc32f6AbF32EC820207dD6751a9334CeE320cc#code) |
| MiningZap | [`0xB10871397f5Ac0fFDd55E14572F51614C79d888D`](https://etherscan.io/address/0xB10871397f5Ac0fFDd55E14572F51614C79d888D#code) |
| GenesisReserve | [`0x67C879793bA14BB5c63Be691136334578503f359`](https://etherscan.io/address/0x67C879793bA14BB5c63Be691136334578503f359#code) |
| RigShop | [`0x16754Fe2311117EffD6C5CeefD451eb8216Cf48e`](https://etherscan.io/address/0x16754Fe2311117EffD6C5CeefD451eb8216Cf48e#code) (block 26505199) |

Pool id: `0x182b9cd826d5a71b638ab59b38890ce1c57016d7a64ba1b0054c7069e757511f` (ETH/PRIME, 0.30%, tick spacing 60).

## Build and test

Requires [Foundry](https://getfoundry.sh).

```bash
git clone --recursive https://github.com/alexksai/primehash-contracts
cd primehash-contracts
forge test                                     # unit, fuzz and invariant tests
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --mc MainnetForkTest   # against live Uniswap v4
```

## Security

The contracts have not had an independent human audit. An AI-performed code review (by Claude, Anthropic) is available: [audit/PrimeHash-Security-Review-2026-11-26.pdf](audit/PrimeHash-Security-Review-2026-11-26.pdf). It found no critical, high or medium issues; 3 low and 7 informational findings, none fixable in the immutable deployed code. Use at your own risk. LP positions are exposed to impermanent loss and to PRIME price volatility.

Please report vulnerabilities privately through GitHub's "Report a vulnerability" (Security tab), not in public issues.

## License

MIT
