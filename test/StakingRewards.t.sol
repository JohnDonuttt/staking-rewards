// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StakingRewards} from "../src/StakingRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StakingRewardsTest is Test {
    StakingRewards staking;
    MockERC20 stakeToken;
    MockERC20 rewardToken;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant REWARD = 7_000e18;
    uint256 constant DURATION = 7 days;

    function setUp() public {
        stakeToken = new MockERC20("Stake", "STK");
        rewardToken = new MockERC20("Reward", "RWD");
        staking = new StakingRewards(address(stakeToken), address(rewardToken), owner);

        stakeToken.mint(alice, 1_000e18);
        stakeToken.mint(bob, 1_000e18);
        vm.prank(alice);
        stakeToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        stakeToken.approve(address(staking), type(uint256).max);
    }

    function _startPeriod(uint256 reward, uint256 duration) internal {
        rewardToken.mint(address(staking), reward);
        vm.prank(owner);
        staking.notifyRewardAmount(reward, duration);
    }

    // --- staking ---

    function test_stake_updatesBalances() public {
        vm.prank(alice);
        staking.stake(100e18);

        assertEq(staking.balanceOf(alice), 100e18);
        assertEq(staking.totalStaked(), 100e18);
        assertEq(stakeToken.balanceOf(address(staking)), 100e18);
    }

    function test_stake_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakingRewards.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_withdraw_moreThanBalanceReverts() public {
        vm.startPrank(alice);
        staking.stake(100e18);
        vm.expectRevert(StakingRewards.InsufficientBalance.selector);
        staking.withdraw(101e18);
        vm.stopPrank();
    }

    // --- rewards ---

    function test_singleStaker_earnsWholeRewardOverPeriod() public {
        _startPeriod(REWARD, DURATION);

        vm.prank(alice);
        staking.stake(100e18);

        skip(DURATION);
        // rewardRate is floored, so allow a dust-sized rounding error
        assertApproxEqAbs(staking.earned(alice), REWARD, DURATION);
    }

    function test_rewardsStopAfterPeriodFinish() public {
        _startPeriod(REWARD, DURATION);
        vm.prank(alice);
        staking.stake(100e18);

        skip(DURATION);
        uint256 atEnd = staking.earned(alice);
        skip(30 days);

        assertEq(staking.earned(alice), atEnd);
    }

    function test_twoStakers_splitProRata() public {
        _startPeriod(REWARD, DURATION);

        vm.prank(alice);
        staking.stake(100e18);
        vm.prank(bob);
        staking.stake(300e18);

        skip(DURATION);

        uint256 a = staking.earned(alice);
        uint256 b = staking.earned(bob);
        assertApproxEqRel(b, a * 3, 1e12);
        assertApproxEqAbs(a + b, REWARD, DURATION);
    }

    function test_lateStaker_missesEarlierRewards() public {
        _startPeriod(REWARD, DURATION);

        vm.prank(alice);
        staking.stake(100e18);
        skip(DURATION / 2);

        vm.prank(bob);
        staking.stake(100e18);
        assertEq(staking.earned(bob), 0);

        skip(DURATION / 2);
        // alice: full first half + half of the second; bob: half of the second
        assertApproxEqRel(staking.earned(alice), (REWARD * 3) / 4, 1e12);
        assertApproxEqRel(staking.earned(bob), REWARD / 4, 1e12);
    }

    function test_getReward_paysOutAndResets() public {
        _startPeriod(REWARD, DURATION);
        vm.prank(alice);
        staking.stake(100e18);
        skip(DURATION);

        uint256 owed = staking.earned(alice);
        vm.prank(alice);
        staking.getReward();

        assertEq(rewardToken.balanceOf(alice), owed);
        assertEq(staking.earned(alice), 0);
    }

    function test_exit_returnsStakeAndReward() public {
        _startPeriod(REWARD, DURATION);
        vm.prank(alice);
        staking.stake(100e18);
        skip(DURATION);

        vm.prank(alice);
        staking.exit();

        assertEq(stakeToken.balanceOf(alice), 1_000e18);
        assertGt(rewardToken.balanceOf(alice), 0);
        assertEq(staking.balanceOf(alice), 0);
    }

    function test_noStakers_rewardsDoNotAccrueToNobody() public {
        _startPeriod(REWARD, DURATION);
        skip(DURATION / 2);

        vm.prank(alice);
        staking.stake(100e18);
        skip(DURATION / 2);

        // only the second half was earned by anyone
        assertApproxEqRel(staking.earned(alice), REWARD / 2, 1e12);
    }

    // --- notifyRewardAmount ---

    function test_notify_onlyOwner() public {
        vm.prank(alice);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        staking.notifyRewardAmount(REWARD, DURATION);
    }

    function test_notify_revertsIfUnderfunded() public {
        rewardToken.mint(address(staking), REWARD - 1e18);
        vm.prank(owner);
        vm.expectRevert(StakingRewards.RewardTooHigh.selector);
        staking.notifyRewardAmount(REWARD, DURATION);
    }

    function test_notify_rollsOverLeftover() public {
        _startPeriod(REWARD, DURATION);
        vm.prank(alice);
        staking.stake(100e18);
        skip(DURATION / 2);

        // top up mid-period with the same duration: leftover + new gets spread again
        _startPeriod(REWARD, DURATION);
        skip(DURATION);

        // 3500 earned in the first half + (3500 leftover + 7000 new) over the new period
        assertApproxEqRel(staking.earned(alice), 14_000e18, 1e12);
    }

    function test_notify_differentDurationMidPeriodReverts() public {
        _startPeriod(REWARD, DURATION);
        skip(1 days);

        rewardToken.mint(address(staking), REWARD);
        vm.prank(owner);
        vm.expectRevert(StakingRewards.PeriodNotFinished.selector);
        staking.notifyRewardAmount(REWARD, DURATION * 2);
    }

    // --- fuzz ---

    function testFuzz_stakeThenWithdraw_roundTrips(uint96 amount) public {
        amount = uint96(bound(amount, 1, 1_000e18));

        vm.startPrank(alice);
        staking.stake(amount);
        staking.withdraw(amount);
        vm.stopPrank();

        assertEq(stakeToken.balanceOf(alice), 1_000e18);
        assertEq(staking.totalStaked(), 0);
    }

    function testFuzz_earnedNeverExceedsFunded(uint96 aliceAmt, uint96 bobAmt, uint32 waitA, uint32 waitB)
        public
    {
        aliceAmt = uint96(bound(aliceAmt, 1, 1_000e18));
        bobAmt = uint96(bound(bobAmt, 1, 1_000e18));
        waitA = uint32(bound(waitA, 0, DURATION));
        waitB = uint32(bound(waitB, 0, 30 days));

        _startPeriod(REWARD, DURATION);

        vm.prank(alice);
        staking.stake(aliceAmt);
        skip(waitA);
        vm.prank(bob);
        staking.stake(bobAmt);
        skip(waitB);

        assertLe(staking.earned(alice) + staking.earned(bob), REWARD);
    }
}
