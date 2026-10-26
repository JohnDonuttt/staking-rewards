// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StakingRewards
/// @notice Stake one token, earn another at a fixed rate spread over a reward period.
/// @dev Reward accounting follows the "reward per token" pattern from Synthetix:
///      instead of looping over stakers, a global accumulator is updated on every
///      state change and each user settles against it lazily.
contract StakingRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    uint256 public periodFinish;
    uint256 public rewardRate; // reward tokens per second
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public totalStaked;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 duration);

    error ZeroAmount();
    error PeriodNotFinished();
    error RewardTooHigh();
    error InsufficientBalance();

    constructor(address _stakingToken, address _rewardToken, address _owner) Ownable(_owner) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    // ---------------------------------------------------------------------
    // views
    // ---------------------------------------------------------------------

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
        return rewardPerTokenStored + (elapsed * rewardRate * PRECISION) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        uint256 delta = rewardPerToken() - userRewardPerTokenPaid[account];
        return rewards[account] + (balanceOf[account] * delta) / PRECISION;
    }

    // ---------------------------------------------------------------------
    // user actions
    // ---------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        totalStaked += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[msg.sender]) revert InsufficientBalance();

        totalStaked -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Withdraw everything and claim whatever is owed.
    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    // ---------------------------------------------------------------------
    // admin
    // ---------------------------------------------------------------------

    /// @notice Start a new reward period. Any leftover from the previous period is rolled in.
    /// @dev The reward tokens must already be sitting in the contract. We check the balance
    ///      rather than pulling them so the owner can fund from a multisig or a streamer.
    function notifyRewardAmount(uint256 reward, uint256 duration)
        external
        onlyOwner
        updateReward(address(0))
    {
        if (duration == 0) revert ZeroAmount();
        if (block.timestamp < periodFinish && duration != rewardsDuration) {
            // changing the duration mid-period would distort the leftover calculation
            revert PeriodNotFinished();
        }

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / duration;
        }

        // the contract must hold enough reward tokens to pay out the whole period.
        // if stakingToken == rewardToken, staked funds don't count towards this.
        uint256 balance = rewardToken.balanceOf(address(this));
        if (address(rewardToken) == address(stakingToken)) {
            balance -= totalStaked;
        }
        if (rewardRate * duration > balance) revert RewardTooHigh();

        rewardsDuration = duration;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;

        emit RewardAdded(reward, duration);
    }
}
