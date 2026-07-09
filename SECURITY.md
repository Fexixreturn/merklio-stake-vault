# Security

In-house security review of the Merklio stake vault. This documents the threat model,
the bugs found and fixed during review, the deliberate design-level defenses, and the
test/verification coverage that backs each claim. Every claim below points at a runnable
proof (`forge test`), not prose.

## Scope and assets

| Contract | Role | Trust boundary |
|---|---|---|
| `MerklioStakeVault` (UUPS) | Pooled deposits, mLST share accounting, buffered reward release | Owner (2-step), Rewarder, Chainlink Automation keeper (**untrusted**) |
| `MerklioStateReceiver` (CCIPReceiver) | Receives cross-chain state over CCIP | CCIP router + **allow-listed** source sender only |

Asset at risk: depositor principal and the share/asset exchange rate. The keeper and the
CCIP path are treated as untrusted inputs and are revalidated on-chain.

## Findings fixed during review (3 real bugs)

### 1. Vacuous invariant — High (false assurance)
The original invariant asserted `uint256 >= 0`, which is always true and tested nothing.
A repo advertising invariant testing effectively had zero economic coverage.
**Fix:** replaced with two real economic invariants, fuzzed 64 runs x 2048 calls, 0 reverts,
with a handler that includes a direct-`donate()` action.
**Proof:** `invariant_sharesFullyBacked`, `invariant_assetsFullyAccounted`.

### 2. Reward-release sandwich — High (value theft)
Rewards were released in a single step into the share price. An attacker could deposit in
the block immediately before release and withdraw right after, capturing rewards they never
earned, diluting honest stakers.
**Fix:** linear drip. Reward is vested over an interval (`releaseAmount`/`releaseStart`/
`releaseEnd`); `_settle()` runs on every deposit and withdraw; `performUpkeep` only opens
the vesting window. Value accrues continuously, so it cannot be front-run in one block.
**Proof:** `test_Drip_NoSandwichProfit` (asserts the sandwich attacker nets exactly 0).

### 3. Zero-share mint / first-depositor donation — Medium to High
A crafted first deposit plus a direct token donation could mint zero shares or inflate the
share price (the classic ERC4626 inflation / donation attack).
**Fix:** a `ZeroShares` revert guard, and the share price is derived from the internal
`totalPooled` accounting, never `balanceOf` — so a direct token transfer into the contract
cannot move the exchange rate.
**Proof:** `test_Deposit_ZeroSharesReverts`, `test_FirstDepositMintsOneToOne`,
`test_SecondDepositorPaysPostRewardPrice`.

## Design-level defenses (deliberate, not bugs)

- **Donation-attack immunity by construction.** Price comes from internal accounting
  (`totalPooled` + vested), never `balanceOf`, so unsolicited transfers cannot skew it.
- **Untrusted keeper model.** `checkUpkeep` is advisory only; `performUpkeep` re-validates
  every precondition on-chain (interval elapsed, buffer non-empty), so a malicious or buggy
  keeper cannot force an early or empty release.
  Proof: `test_PerformUpkeep_RevertsBeforeInterval`, `test_PerformUpkeep_RevertsWithNothingToRelease`.
- **Cross-chain report hardening.** `MerklioStateReceiver` ignores stale / out-of-order CCIP
  reports and rejects any non-allow-listed sender.
  Proof: `test_Receiver_IgnoresStaleReport`, `test_Receiver_RejectsUnknownSender`.
- **Minimized owner surface.** `Ownable2Step` (two-phase transfer, no fat-finger loss);
  owner-settable `ccipGasLimit` emits an event.
- **Upgrade safety.** UUPS with an append-only storage gap; state is preserved across an
  upgrade in test. Proof: `test_UpgradePreservesState`, `test_Upgrade_OnlyOwner`.

## Verification coverage

- **21 tests** (19 unit + 2 invariant), Foundry. `forge test` is green.
- **Invariants** (64 runs x 2048 calls, 0 reverts):
  - `invariant_sharesFullyBacked` — `previewRedeem(totalSupply) <= totalAssets`; no share is
    unbacked (catches over-mint / phantom value).
  - `invariant_assetsFullyAccounted` — pooled + vested reconciles; no asset is created or lost,
    and it holds even after a direct donation.
- **Gas** — regression-tracked in `.gas-snapshot` (`forge snapshot`).
- **Static analysis** — `slither.config.json` is included; CI runs `slither .` (excludes
  vendored Chainlink interfaces and tests). *Honest note: not executed in the demo box
  (constrained disk); wired for CI.*
- **Formal verification** — contracts are Certora-ready (explicit invariants, clean storage
  layout). A CVL spec is out of scope for this demo.

## Known limitations (honest)

- Slither / Certora are CI steps, not run in this environment.
- Single-asset vault; multi-asset and per-user locks are out of scope.
- Chainlink Automation/CCIP interfaces are vendored under `src/vendor` for a self-contained
  demo; swap for the canonical router addresses on a real deployment.
