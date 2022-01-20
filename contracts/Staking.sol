// SPDX-License-Identifier: MIT
import "./CAKE.sol";
import "./DividendPool.sol";
import "./HitchensUnorderedAddressSet.sol";
import "./LePeuple.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";

pragma solidity ^0.8.0;

contract Staking is Ownable {
    uint256 public currentBlockCreationTime = block.timestamp;
    uint256 public currentBlockNumber = 0;
    uint256 private currentBlockCakeRewards = 0;

    address private immutable peuple;
    address private immutable cake;
    SwapPool private immutable swapPool;

    uint256 public constant MAX_STAKE = (2**32 - 1) * 1 ether;

    uint256 public minimumCakeForSwap = 10 ether; // TODO setter
    uint256 public minimumPeupleForBlockCreation = 10e6 ether; // TODO setter

    uint256 public currentTotalStake = 0;
    uint256 public currentTotalPonderedStake = 0;
    uint256 public currentTotalOwnedPeuple = 0;

    uint256 public percentBonusForTwoMonthStaking = 50; // TODO setter
    uint256 public percentBonusForThreeMonthStaking = 100; // TODO setter

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

    constructor(
        address _peuple,
        address _cake,
        SwapPool _swapPool
    ) {
        cake = _cake;
        peuple = _peuple;
        swapPool = _swapPool;
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
        onlyOwner
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

    function stake(uint256 amount, uint256 months) external {
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
        require(allowance >= amount, "Staking: check allowance");
        IERC20(peuple).transferFrom(msg.sender, address(this), amount);

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
        return true;
    }

    function unstake(uint256 stakeIndex) external returns (uint256) {
        createNewBlock();

        HolderStake[] storage stakes = holderStakes[msg.sender];
        HolderStake storage holderStake = stakes[stakeIndex];
        if (holderStake.blockedUntil < block.timestamp) {
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
            IERC20(peuple).transfer(msg.sender, amountToWithdraw);
            return amountToWithdraw;
        } else {
            return 0;
        }
    }

    function sendCakeRewards(uint256 cakeRewards) external {
        IERC20(cake).transferFrom(msg.sender, address(this), cakeRewards);
        currentBlockCakeRewards += cakeRewards;

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
        external
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
        if (currentBlockAge < 1 days || currentTotalStake == 0) return false;
        uint256 cakeBalance = IERC20(cake).balanceOf(address(this));
        if (cakeBalance >= minimumCakeForSwap) return true;
        uint256 peupleBalance = IERC20(peuple).balanceOf(address(this));
        uint256 peupleRewardsInCurrentBlock = peupleBalance -
            currentTotalOwnedPeuple;
        return peupleRewardsInCurrentBlock >= minimumPeupleForBlockCreation;
    }

    function createNewBlock() public {
        uint256 currentBlockAge = block.timestamp - currentBlockCreationTime;
        if (currentBlockAge < 1 days || currentTotalStake == 0) return;
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
        IERC20(peuple).transfer(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    function swapCakeForTokens(uint256 amount) internal returns (uint256) {
        IERC20(cake).approve(address(swapPool), amount);
        return swapPool.convertCakeIntoPeuple(address(this), amount);
    }
}
