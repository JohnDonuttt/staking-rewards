// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../../src/StakingRewards.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// Bounded random actions against the staking contract. Ghost variables track what
/// *should* be true so the invariant test can compare against on-chain state.
contract Handler is Test {
    StakingRewards public staking;
    MockERC20 public stakeToken;
    MockERC20 public rewardToken;

    address[] public actors;
    uint256 public ghostTotalStaked;
    uint256 public ghostRewardsPaid;

    constructor(StakingRewards _staking, MockERC20 _stakeToken, MockERC20 _rewardToken) {
        staking = _staking;
        stakeToken = _stakeToken;
        rewardToken = _rewardToken;

        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            stakeToken.mint(actor, 1_000_000e18);
            vm.prank(actor);
            stakeToken.approve(address(staking), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, stakeToken.balanceOf(actor));
        if (amount == 0) return;

        vm.prank(actor);
        staking.stake(amount);
        ghostTotalStaked += amount;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal = staking.balanceOf(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(actor);
        staking.withdraw(amount);
        ghostTotalStaked -= amount;
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 before = rewardToken.balanceOf(actor);

        vm.prank(actor);
        staking.getReward();
        ghostRewardsPaid += rewardToken.balanceOf(actor) - before;
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 1, 3 days));
    }
}
