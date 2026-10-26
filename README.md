# staking-rewards

A small staking contract: stake one ERC-20, earn another at a fixed rate over a reward period. Built with Foundry and OpenZeppelin v5.

I wrote this to practice the "reward per token" accounting pattern (the one Synthetix popularised) and to see how far fuzz and invariant tests can take a contract this size. It is not audited, so don't put real funds in it.

## How it works

Looping over every staker to distribute rewards doesn't scale. Instead the contract keeps one global accumulator, `rewardPerTokenStored`, which grows by `rewardRate * dt / totalStaked` each time anyone touches the contract. A user's pending reward is just:

```
earned = rewards[user] + balance[user] * (rewardPerToken - userRewardPerTokenPaid[user])
```

so every call is O(1) no matter how many stakers there are.

| Function | Who | What |
| --- | --- | --- |
| `stake(amount)` | anyone | Deposit staking tokens |
| `withdraw(amount)` | staker | Take stake back, keep accruing on the rest |
| `getReward()` | staker | Claim accrued rewards |
| `exit()` | staker | `withdraw` everything + `getReward` |
| `notifyRewardAmount(reward, duration)` | owner | Start (or extend) a reward period |

### Design decisions

- **Funding is checked, not pulled.** `notifyRewardAmount` reverts if the contract's reward balance can't cover `rate * duration`. The owner transfers tokens first, so funding can come from a multisig or a streaming contract. If the stake and reward tokens are the same, staked funds are excluded from the check.
- **Leftovers roll over.** Calling `notifyRewardAmount` mid-period folds the unspent rewards into the new rate rather than stranding them.
- **No duration changes mid-period.** Changing the duration while a period is live makes the leftover math ambiguous, so it reverts with `PeriodNotFinished`.
- **Rewards don't accrue to nobody.** If nobody is staked, time still passes but nothing is credited. Those rewards stay in the contract (see Known limitations).
- **`ReentrancyGuard` + checks-effects-interactions** on every state-changing user function, even though the tokens are assumed to be plain ERC-20s.

## Testing

```sh
forge test            # unit + fuzz + invariants
forge coverage --report summary
```

| Suite | What it covers |
| --- | --- |
| `test/StakingRewards.t.sol` | Staking and withdrawing, pro-rata splits, late joiners, period end, rollover, access control, underfunding |
| `testFuzz_*` | Stake/withdraw round trips; total earned never exceeds what was funded |
| `test/invariant/` | Random sequences of stake / withdraw / claim / time-warp across 4 actors |

Invariants checked after every call sequence:

1. `totalStaked` equals the sum of balances and the contract's actual staking-token balance.
2. Total rewards paid never exceed the funded amount.
3. Paid + still-owed never exceeds the funded amount, and the contract can always cover what's owed.

Line coverage on `StakingRewards.sol` is about 91%.

## Known limitations

- Because `rewardRate` is `reward / duration` (integer division), up to `duration - 1` wei of rewards are left behind each period.
- If no one is staked for part of a period, those rewards are never distributed. Fixing it would mean extending `periodFinish`, which I left out to keep the accounting simple.
- Fee-on-transfer and rebasing tokens are not supported.
- No pause, no emergency withdraw, no timelock on the owner.

## Deploy

```sh
cp .env.example .env   # STAKING_TOKEN, REWARD_TOKEN, OWNER, RPC_URL
source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

Then transfer the reward tokens to the contract and call `notifyRewardAmount` from the owner.

## Layout

```
src/StakingRewards.sol
script/Deploy.s.sol
test/StakingRewards.t.sol
test/invariant/{Handler,StakingRewards.invariant.t}.sol
test/mocks/MockERC20.sol
```

## License

MIT
