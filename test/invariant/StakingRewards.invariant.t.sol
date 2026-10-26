// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Handler} from "./Handler.sol";

contract StakingRewardsInvariantTest is Test {
    StakingRewards staking;
    MockERC20 stakeToken;
    MockERC20 rewardToken;
    Handler handler;

    uint256 constant FUNDED = 100_000e18;

    function setUp() public {
        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");
        staking = new StakingRewards(address(stakeToken), address(rewardToken), address(this));

        rewardToken.mint(address(staking), FUNDED);
        staking.notifyRewardAmount(FUNDED, 30 days);

        handler = new Handler(staking, stakeToken, rewardToken);
        targetContract(address(handler));
    }

    /// Every staked token is accounted for, and the contract actually holds them.
    function invariant_stakeAccounting() public view {
        assertEq(staking.totalStaked(), handler.ghostTotalStaked());
        assertEq(stakeToken.balanceOf(address(staking)), staking.totalStaked());
    }

    /// totalStaked is exactly the sum of individual balances.
    function invariant_balancesSumToTotal() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += staking.balanceOf(handler.actors(i));
        }
        assertEq(sum, staking.totalStaked());
    }

    /// We can never pay out more than was funded.
    function invariant_neverOverpays() public view {
        assertLe(handler.ghostRewardsPaid(), FUNDED);
    }

    /// Paid + still-owed stays within the funded amount.
    function invariant_solvent() public view {
        uint256 owed;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            owed += staking.earned(handler.actors(i));
        }
        assertLe(handler.ghostRewardsPaid() + owed, FUNDED);
        assertGe(rewardToken.balanceOf(address(staking)), owed);
    }
}
