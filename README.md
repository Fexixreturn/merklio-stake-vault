# Merklio Stake Vault — Chainlink Automation + CCIP demo

A compact, fully-tested **liquid-staking vault** that exercises exactly the engineering surface in the
Merklio *Smart Contract Engineer* brief: a **UUPS-upgradeable** vault with role-gated rewards,
**Chainlink Automation** for scheduled reward drips, and **Chainlink CCIP** to mirror vault state to
another chain — all covered by unit **and invariant** tests in Foundry.

Built as a focused proof piece. Solidity is my core; this is the kind of contract I write day to day.

## How it maps to the brief

| Brief expectation | Where |
|---|---|
| Design & deploy **upgradeable proxy contracts (UUPS)** | `MerklioStakeVault` (ERC1967 proxy + `_authorizeUpgrade`), `script/Deploy.s.sol`, upgrade tests |
| High-assurance tests with **invariant testing (Foundry)** | `test/invariant/InvariantStakeVault.t.sol` — solvency + full-backing invariants (incl. adversarial donations), 64 runs × 2048 calls |
| **Access control (Ownable2Step, roles)** | `Ownable2StepUpgradeable` owner + `rewarders` role + `onlyRewarder` |
| Vault contracts, **liquid-staking tokens, reward distribution** | `mLST` share token; `deposit`/`withdraw` at live exchange rate; buffered → linearly dripped rewards |
| **Chainlink Automation** | `checkUpkeep` / `performUpkeep` start a reward drip window on an interval |
| **Chainlink CCIP** | `reportStateCrossChain` (sender) → `MerklioStateReceiver` (`CCIPReceiver`) on the destination chain |
| **Natspec + deployment scripts** | full Natspec across `src/`, `script/Deploy.s.sol` |
| **Optimize storage layouts** | packed config slots (`address`+`uint64`, 3×`uint64`), upgrade-safe `__gap` |

## Architecture

```
Source chain                                   Destination chain
┌─────────────────────────────┐   CCIP msg    ┌──────────────────────────┐
│ MerklioStakeVault (UUPS)     │ ───────────▶  │ MerklioStateReceiver      │
│  • deposit/withdraw → mLST   │  ccipSend     │  • CCIPReceiver base      │
│  • fundRewards (rewarder)    │               │  • allow-listed sender    │
│  • Automation: drip rewards  │               │  • stores latest state    │
│  • CCIP sender: report state │               └──────────────────────────┘
└─────────────────────────────┘
```

### Reward / share model
Share price = `totalAssets / totalSupply` (1:1 on first deposit). Rewards are funded into a
`rewardBuffer`; once the interval elapses, Chainlink Automation starts a **drip window** and the
buffer **vests linearly** into the share price over `distributionInterval`. Linear vesting (instead
of a step release) means a release can't be sandwiched — depositing right before `performUpkeep`
and exiting right after captures nothing (covered by `test_Drip_NoSandwichProfit`). Deposits that
would round to zero shares revert instead of silently donating to existing holders. Core solvency
invariant, proven by fuzzing (including adversarial direct donations):

```
asset.balanceOf(vault) == totalPooled + rewardBuffer + releaseAmount + donations
```

The vault prices shares off internal accounting, never `balanceOf`, so donation-based share
inflation is impossible by construction; donated assets sit unaccounted by design (no sweep).
Standard ERC-20 semantics are assumed (no fee-on-transfer / rebasing).

### Chainlink integration
- **Automation:** the vault implements `AutomationCompatibleInterface`. `checkUpkeep` is the off-chain
  predicate (`buffer > 0 && interval elapsed`); `performUpkeep` re-validates on-chain before starting
  the drip window.
- **CCIP:** `reportStateCrossChain` builds a `Client.EVM2AnyMessage` (state payload, native-token fee,
  `EVMExtraArgsV1` with an owner-settable gas limit), quotes via `getFee`, dispatches via
  `IRouterClient.ccipSend`, and refunds excess native. The receiver extends `CCIPReceiver`, accepts
  only an allow-listed `(sourceChainSelector, sender)` pair, and ignores out-of-order (stale)
  reports — CCIP does not guarantee message ordering.

The Chainlink interfaces (`AutomationCompatibleInterface`, `Client`, `IRouterClient`,
`IAny2EVMMessageReceiver`, `CCIPReceiver`) are vendored under `src/vendor/chainlink/` with **faithful
signatures**, so the contracts are drop-in against the real CCIP router on testnet/mainnet. CCIP is
tested end-to-end locally via `test/mocks/MockCCIPRouter.sol`, which delivers the message to the
receiver synchronously (swap in a real router address on Sepolia — see `Deploy.s.sol`).

## Test it

```bash
forge test            # 19 unit/integration tests + 2 invariants, all green
forge test -vvv --match-path 'test/invariant/*'
```

```
[PASS] invariant_assetsFullyAccounted (runs: 64, calls: 2048)
[PASS] invariant_sharesFullyBacked (runs: 64, calls: 2048)
... 21 passed; 0 failed
```

## Deploy (Sepolia example)

```bash
ASSET=0x... CCIP_ROUTER=0x... DEST_CHAIN_SELECTOR=... DEST_ROUTER=0x... \
PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url $SEPOLIA --broadcast
```
Real router addresses / chain selectors come from the Chainlink CCIP directory.

## Layout

```
src/
  MerklioStakeVault.sol      UUPS vault: staking, rewards, Automation, CCIP sender
  MerklioStateReceiver.sol   CCIPReceiver: allow-listed cross-chain state mirror
  vendor/chainlink/          faithful vendored Chainlink interfaces (Automation + CCIP)
test/
  MerklioStakeVault.t.sol     19 unit/integration tests (staking, drip, Automation, CCIP, UUPS, Ownable2Step)
  invariant/                  solvency + full-backing invariants, handler w/ donation action
  mocks/                      MockCCIPRouter (sync delivery), MockERC20
script/Deploy.s.sol          proxy + receiver deployment, CCIP wiring
```

— Fenix Return · github.com/Fexixreturn
