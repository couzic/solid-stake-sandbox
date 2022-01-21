// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HitchensUnorderedAddressSet.sol";
import "./OwnableStaking.sol";
import "./PausableStaking.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";

import "./IUniswapV2Pair.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router.sol";

contract Staking is Ownable, Pausable, ReentrancyGuard {

    using SafeERC20 for IERC20;

    uint256 public currentBlockCreationTime = block.timestamp;
    uint256 public currentBlockNumber = 0;
    uint256 public minimumBlockAge = 1 days;
    uint256 private currentBlockCakeRewards = 0;

    address public peuple = address(0x0Bcc37174f0f322b8b9c81b5C51c90B49e5669Be);
    address public cake = address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    IUniswapV2Router02 public uniswapV2Router;

    uint256 public constant MAX_STAKE = (2**32 - 1) * 1 ether;

    uint256 public minimumCakeForSwap = 1 ether; // TODO ++
    uint256 public minimumPeupleForBlockCreation = 1 ether; // TODO ++

    uint256 public currentTotalStake = 0;
    uint256 public currentTotalPonderedStake = 0;
    uint256 public currentTotalOwnedPeuple = 0;

    uint256 public percentBonusForTwoMonthStaking = 50;
    uint256 public percentBonusForThreeMonthStaking = 100;

    uint256 public minimumGasForBlockComputation = 70000; // TODO setter
    uint256 public minimumGasForPeupleTransfer = 400000; // TODO setter

    struct HolderStake {
        uint256 amount;
        uint256 timeBonusPonderedAmount;
        uint256 startBlock;
        uint256 blockedUntil;
        uint256 precomputedUntilBlock;
        uint256 precomputedClaimableRewards;
        uint256 precomputedUnclaimableRewards;
        uint256 precomputedDividends;
        uint256 withdrawn;
    }

    struct DayBlock {
        uint256 creationTime;
        uint256 totalStake;
        uint256 totalPonderedStake;
        uint256 dividends;
        uint256 rewards;
    }

    mapping(uint256 => DayBlock) public dayBlocks;

    mapping(address => HolderStake[]) public holderStakes;

    mapping(address => uint256) public holderSocialBonus;

    struct DividendsAndRewards {
        uint256 dividends;
        uint256 claimableRewards;
        uint256 unclaimableRewards;
    }
    
    event Stake(address staker, uint256 amount, uint256 duration);
    event Restake(address staker, uint duration);
    event Unstake(address staker, uint256 amount);
    event Swap(uint256 cake, uint256 peuple);
    event NewBlock(uint256 id, uint256 time);
    event RewardsReceived(uint cake);
    event StakingEnded();

    constructor() Pausable() ReentrancyGuard() {
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        uniswapV2Router = _uniswapV2Router;
    }

    function setPercentBonusForTwoMonthStaking(uint256 bonus)
        external 
        onlyOwner
    {
        require(bonus <= 100, "Staking: bonus for 2 months <= 100");
        percentBonusForTwoMonthStaking = bonus;
    }

    function setPercentBonusForThreeMonthStaking(uint256 bonus)
        external
        onlyOwner
    {
        require(bonus <= 200, "Staking: bonus for 3 months <= 200");
        percentBonusForThreeMonthStaking = bonus;
    }

    function setHolderSocialBonus(address staker, uint256 bonus)
        external
        onlyPusher
        returns (bool)
    {
        require(bonus <= 200, "Staking: social bonus <= 200");
        uint256 currentSocialBonus = holderSocialBonus[staker];
        require(currentSocialBonus != bonus, "Staking: same social bonus");
        HolderStake[] storage stakes = holderStakes[staker];
        for (uint256 i = 0; i < stakes.length; i++) {
            HolderStake storage holderStake = stakes[i];
            bool precomputed = precomputeDividendsAndRewards(
                holderStake,
                currentSocialBonus
            );
            if (!precomputed) return false;
        }
        // TODO return false if not enough gas to finish
        uint256 currentHolderPonderedStake = computePonderedStakes(
            stakes,
            currentSocialBonus
        );
        holderSocialBonus[staker] = bonus;
        currentTotalPonderedStake -= currentHolderPonderedStake;
        currentTotalPonderedStake += computePonderedStakes(stakes, bonus);
        return true;
    }

    function setMinimumCakeForSwap(uint256 _minimumCakeForSwap) external onlyOwner {
        require(_minimumCakeForSwap > 0, "Should be more than 0 wei");
        minimumCakeForSwap = _minimumCakeForSwap;
        createNewBlock();
    }
    
    function setMinimumBlockAge(uint256 _minimumBlockAge) external onlyOwner {
        require(_minimumBlockAge > 0, "Should be more than 0 secondes");
        minimumBlockAge = _minimumBlockAge;
        createNewBlock();
    }

    function setPeupleAddress(address _peuple) external onlyOwner {
        peuple = _peuple;
    }

    function setCakeAddress(address _cake) external onlyOwner {
        cake = _cake;
    }

    function stake(uint256 amount, uint256 months) external whenNotPaused {
        require(amount >= 1 ether, "Staking: Cannot stake less than 1 token");
        require(
            amount <= MAX_STAKE,
            "Staking: Cannot stake more than ~4B tokens"
        );
        require(months > 0 && months < 4, "Staking: 1, 2 or 3 months only");
        HolderStake[] storage stakes = holderStakes[msg.sender];
        require(stakes.length < 10, "Staking limited to 10 slots");

        uint256 timeBonusPonderedAmount = computeTimeBonusPonderedStakeAmount(
            amount,
            months
        );

        uint256 blockedUntil = block.timestamp + months * 30 days;

        stakes.push(
            HolderStake(
                amount,
                timeBonusPonderedAmount,
                currentBlockNumber,
                blockedUntil,
                currentBlockNumber, // precomputedUntilBlock
                0, // precomputedClaimableRewards
                0, // precomputedUnclaimableRewards
                0, // precomputedDividends
                0 // withdrawn
            )
        );
        HolderStake storage holderStake = stakes[stakes.length - 1];
        currentTotalStake += amount;
        uint256 socialBonus = holderSocialBonus[msg.sender];
        currentTotalPonderedStake += computePonderedStake(
            holderStake,
            socialBonus
        );
        currentTotalOwnedPeuple += amount;
        uint256 allowance = IERC20(peuple).allowance(msg.sender, address(this));
        require(allowance >= amount, "Staking: check the PEUPLE allowance"); 
        IERC20(peuple).safeTransferFrom(msg.sender, address(this), amount);

        emit Stake(msg.sender, amount, months);
        createNewBlock();
    }

    function computeTimeBonusPonderedStakeAmount(uint256 amount, uint256 months)
        internal
        view
        returns (uint256 timeBonusPonderedAmount)
    {
        timeBonusPonderedAmount = amount;
        if (months == 2) {
            timeBonusPonderedAmount +=
                (amount * percentBonusForTwoMonthStaking) /
                100;
        }
        if (months == 3) {
            timeBonusPonderedAmount +=
                (amount * percentBonusForThreeMonthStaking) /
                100;
        }
    }

    function restake(uint256 stakeIndex, uint256 months)
        external
        returns (bool)
    {
        require(months > 0 && months < 4, "Restaking: 1, 2 or 3 months only");
        HolderStake[] storage stakes = holderStakes[msg.sender];
        HolderStake storage holderStake = stakes[stakeIndex];
        require(
            holderStake.blockedUntil < block.timestamp,
            "Restaking: stake still blocked"
        );
        bool precomputed = precomputeDividendsAndRewards(
            holderStake,
            holderSocialBonus[msg.sender]
        );
        // TODO Test precomputations AND enough gas to finalize
        // if (!precomputed) return false;
        holderStake.blockedUntil = block.timestamp + months * 30 days;
        uint256 newTimeBonusPonderedStakeAmount = computeTimeBonusPonderedStakeAmount(
                holderStake.amount,
                months
            );
        currentTotalPonderedStake -= holderStake.timeBonusPonderedAmount;
        currentTotalPonderedStake += newTimeBonusPonderedStakeAmount;
        holderStake.timeBonusPonderedAmount = newTimeBonusPonderedStakeAmount;
        emit Restake(msg.sender, months);
        return true;
    }

    function unstake(uint256 stakeIndex) external nonReentrant returns (uint256) {
        createNewBlock();

        HolderStake[] storage stakes = holderStakes[msg.sender];
        HolderStake storage holderStake = stakes[stakeIndex];
        if (holderStake.blockedUntil < block.timestamp || paused()) {
            DividendsAndRewards
                memory dividendsAndRewards = computeDividendsAndRewardsFor(
                    holderStake
                );
            uint256 amountToWithdraw = holderStake.amount +
                claimable(dividendsAndRewards) -
                holderStake.withdrawn;
            currentTotalStake -= holderStake.amount;
            currentTotalPonderedStake -= computePonderedStake(
                holderStake,
                holderSocialBonus[msg.sender]
            );
            currentTotalOwnedPeuple -= amountToWithdraw;
            // Release unclaimable rewards
            currentTotalOwnedPeuple -= dividendsAndRewards.unclaimableRewards;
            stakes[stakeIndex] = stakes[stakes.length - 1];
            stakes.pop();
            IERC20(peuple).safeTransfer(msg.sender, amountToWithdraw);
            return amountToWithdraw;
        } else {
            return 0;
        }
    }

    function sendCakeRewards(uint256 cakeRewards) external {
        uint256 allowance = IERC20(cake).allowance(msg.sender, address(this));
        require(allowance >= cakeRewards, "Staking: check the CAKE allowance"); 

        IERC20(cake).safeTransferFrom(msg.sender, address(this), cakeRewards);
        currentBlockCakeRewards += cakeRewards;

        emit RewardsReceived(cakeRewards);
        createNewBlock();
    }

    function totalStaked() external view returns (uint256) {
        return currentTotalStake;
    }

    function computeHolderStake() external view returns (uint256) {
        HolderStake[] storage stakes = holderStakes[msg.sender];
        uint256 arrayLength = stakes.length;
        uint256 total = 0;
        for (uint256 i = 0; i < arrayLength; i++) {
            total += stakes[i].amount;
        }
        return total;
    }

    function computePonderedStakes(
        HolderStake[] storage stakes,
        uint256 socialBonus
    ) internal view returns (uint256) {
        uint256 arrayLength = stakes.length;
        uint256 total = 0;
        for (uint256 i = 0; i < arrayLength; i++) {
            total += computePonderedStake(stakes[i], socialBonus);
        }
        return total;
    }

    function computePonderedStake(
        HolderStake storage holderStake,
        uint256 socialBonus
    ) internal view returns (uint256) {
        return
            holderStake.timeBonusPonderedAmount +
            (holderStake.amount * socialBonus) /
            100;
    }

    function computeDividends(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            computeDividendsAndRewardsFor(holderStakes[msg.sender][stakeIndex])
                .dividends;
    }

    function computeRewards(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            computeDividendsAndRewardsFor(holderStakes[msg.sender][stakeIndex])
                .claimableRewards;
    }

    function computeDividendsAndRewards(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            claimable(
                computeDividendsAndRewardsFor(
                    holderStakes[msg.sender][stakeIndex]
                )
            );
    }

    function claimable(DividendsAndRewards memory dividendsAndRewards)
        internal
        pure
        returns (uint256)
    {
        return
            dividendsAndRewards.dividends +
            dividendsAndRewards.claimableRewards;
    }

    function computeWithdrawableDividendsAndRewards(uint256 stakeIndex)
        public
        view
        returns (uint256)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        return
            claimable(computeDividendsAndRewardsFor(holderStake)) -
            holderStake.withdrawn;
    }

    function computeDividendsAndRewardsFor(HolderStake storage holderStake)
        internal
        view
        returns (DividendsAndRewards memory)
    {
        uint256 dividends = holderStake.precomputedDividends;
        uint256 claimableRewards = holderStake.precomputedClaimableRewards;
        uint256 unclaimableRewards = holderStake.precomputedUnclaimableRewards;
        uint256 socialBonus = holderSocialBonus[msg.sender];
        for (
            uint256 previousBlockNumber = currentBlockNumber;
            previousBlockNumber > holderStake.precomputedUntilBlock &&
                previousBlockNumber > holderStake.startBlock &&
                previousBlockNumber > 0;
            previousBlockNumber--
        ) {
            uint256 focusedBlockNumber = previousBlockNumber - 1;
            DayBlock storage focusedBlock = dayBlocks[focusedBlockNumber];

            // Dividends
            dividends +=
                (focusedBlock.dividends * holderStake.amount) /
                focusedBlock.totalStake;
            // Base rewards + time bonus
            uint256 rewards = (focusedBlock.rewards *
                holderStake.timeBonusPonderedAmount) /
                focusedBlock.totalPonderedStake;
            // Social bonus rewards
            if (socialBonus > 0) {
                rewards +=
                    (focusedBlock.rewards * holderStake.amount * socialBonus) /
                    (focusedBlock.totalPonderedStake * 100);
            }
            if (focusedBlock.creationTime > holderStake.blockedUntil) {
                // expired
                unclaimableRewards += rewards;
            } else {
                claimableRewards += rewards;
            }
        }
        return
            DividendsAndRewards(
                dividends,
                claimableRewards,
                unclaimableRewards
            );
    }

    function precomputeDividendsAndRewards(
        HolderStake storage holderStake,
        uint256 socialBonus
    ) internal returns (bool) {
        while (holderStake.precomputedUntilBlock < currentBlockNumber) {
            DayBlock storage focusedBlock = dayBlocks[
                holderStake.precomputedUntilBlock
            ];

            // Dividends
            holderStake.precomputedDividends +=
                (focusedBlock.dividends * holderStake.amount) /
                focusedBlock.totalStake;
            // Base rewards + time bonus
            uint256 rewards = (focusedBlock.rewards *
                holderStake.timeBonusPonderedAmount) /
                focusedBlock.totalPonderedStake;
            // Social bonus rewards
            if (socialBonus > 0) {
                rewards +=
                    (focusedBlock.rewards * holderStake.amount * socialBonus) /
                    (focusedBlock.totalPonderedStake * 100);
            }
            if (focusedBlock.creationTime > holderStake.blockedUntil) {
                // expired
                holderStake.precomputedUnclaimableRewards += rewards;
            } else {
                holderStake.precomputedClaimableRewards += rewards;
            }
            holderStake.precomputedUntilBlock++;
            if (gasleft() < minimumGasForBlockComputation) return false;
        }
        return true;
    }

    function canCreateNewBlock() external view returns (bool) {
        uint256 currentBlockAge = block.timestamp - currentBlockCreationTime;
        if (currentBlockAge < minimumBlockAge || currentTotalStake == 0) return false;
        uint256 cakeBalance = IERC20(cake).balanceOf(address(this));
        if (cakeBalance >= minimumCakeForSwap) return true;
        uint256 peupleBalance = IERC20(peuple).balanceOf(address(this));
        uint256 peupleRewardsInCurrentBlock = peupleBalance -
            currentTotalOwnedPeuple;
        return peupleRewardsInCurrentBlock >= minimumPeupleForBlockCreation;
    }

    function createNewBlock() public {
        uint256 currentBlockAge = block.timestamp - currentBlockCreationTime;
        if (currentBlockAge < minimumBlockAge || currentTotalStake == 0) return;
        uint256 cakeBalance = IERC20(cake).balanceOf(address(this));
        uint256 peupleBalance = IERC20(peuple).balanceOf(address(this));
        uint256 peupleRewardsInCurrentBlock = peupleBalance -
            currentTotalOwnedPeuple;
        if (
            cakeBalance < minimumCakeForSwap &&
            peupleRewardsInCurrentBlock < minimumPeupleForBlockCreation
        ) return;

        // SWAP
        uint256 swappedPeuple = 0;
        uint256 swappedPeupleRewards = 0;
        if (cakeBalance >= minimumCakeForSwap) {
            swappedPeuple = swapCakeForTokens(cakeBalance);
            swappedPeupleRewards =
                (swappedPeuple * currentBlockCakeRewards) /
                cakeBalance;
        }
        uint256 dividends = swappedPeuple - swappedPeupleRewards;
        uint256 rewards = swappedPeupleRewards + peupleRewardsInCurrentBlock;
        dayBlocks[currentBlockNumber] = DayBlock(
            currentBlockCreationTime,
            currentTotalStake,
            currentTotalPonderedStake,
            dividends,
            rewards
        );
        currentTotalOwnedPeuple += dividends + rewards;
        currentBlockCreationTime = block.timestamp;
        currentBlockNumber += 1;
        currentBlockCakeRewards = 0;

        emit NewBlock(currentBlockNumber, currentBlockCreationTime);
    }

    function withdrawDividendsAndRewards(uint256 stakeIndex)
        external
        returns (uint256)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        bool precomputed = precomputeDividendsAndRewards(
            holderStake,
            holderSocialBonus[msg.sender]
        );
        if (!precomputed || gasleft() < minimumGasForPeupleTransfer) return 0;
        DividendsAndRewards
            memory dividendsAndRewards = computeDividendsAndRewardsFor(
                holderStake
            );
        uint256 amountToWithdraw = claimable(dividendsAndRewards) -
            holderStake.withdrawn;
        holderStake.withdrawn += amountToWithdraw;
        // TODO release unclaimable ?
        currentTotalOwnedPeuple -= amountToWithdraw;
        IERC20(peuple).safeTransfer(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    function swapCakeForTokens(uint256 amount) internal returns (uint) {
        IERC20(cake).approve(address(uniswapV2Router), amount);
    
        address[] memory path = new address[](3);
        path[0] = cake;
        path[1] = uniswapV2Router.WETH(); // WBNB
        path[2] = peuple;

        // Make the swap
        uint[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + 5 minutes
        );

        emit Swap(amount, amounts[2]);
        return amounts[2];
    }

    function getStakeInfo(uint256 stakeIndex)
        external
        view
        returns (
            address holder,
            uint256 id,
            uint256 blockedUntil,
            bool unstakable,
            uint256 staked,
            uint256 availableForWithdraw,
            uint256 dividends,
            uint256 rewards,
            uint256 withdrawn
        )
    {
        holder = msg.sender;
        id = stakeIndex;
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        blockedUntil = holderStake.blockedUntil;
        unstakable = (block.timestamp > blockedUntil) || paused();
        staked = holderStake.amount;
        availableForWithdraw = computeWithdrawableDividendsAndRewards(stakeIndex);
        dividends = computeDividendsAndRewardsFor(holderStake).dividends;
        rewards = computeDividendsAndRewardsFor(holderStake).claimableRewards;
        withdrawn = holderStake.withdrawn;
    }

    function getBonus(address holder) external view returns (address, uint256) {
        return (holder, holderSocialBonus[holder]);
    }

    function emptyStaking() external onlyOwner { // TODO whenPausedLongEnough
        IERC20(peuple).safeTransfer(msg.sender, IERC20(peuple).balanceOf(address(this)));
        IERC20(cake).safeTransfer(msg.sender, IERC20(cake).balanceOf(address(this)));
        
        emit StakingEnded();
    }
}