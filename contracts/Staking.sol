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

    uint256 public bonusForTwoMonthStaking = 50;
    uint256 public bonusForThreeMonthStaking = 100;

    uint256 public minimumGasForBlockComputation = 70000; // TODO setter
    uint256 public minimumGasForPeupleTransfer = 400000; // TODO setter

    struct HolderStake {
        uint256 amount;
        uint256 ponderedAmount;
        uint256 timeBonus;
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

    function setBonusForTwoMonthStaking(uint256 bonus) external onlyOwner {
        require(bonus <= 100, "Staking: bonus for 2 months <= 100");
        bonusForTwoMonthStaking = bonus;
    }

    function setBonusForThreeMonthStaking(uint256 bonus) external onlyOwner {
        require(bonus <= 200, "Staking: bonus for 3 months <= 200");
        bonusForThreeMonthStaking = bonus;
    }

    function setHolderSocialBonus(address holder, uint256 newSocialBonus)
        public
        onlyOwner
        returns (bool)
    {
        require(newSocialBonus <= 200, "Staking: social bonus <= 200");
        uint256 currentSocialBonus = holderSocialBonus[holder];
        require(
            currentSocialBonus != newSocialBonus,
            "Staking: same social bonus"
        );
        HolderStake[] storage stakes = holderStakes[holder];
        for (uint256 i = 0; i < stakes.length; ++i) {
            HolderStake storage holderStake = stakes[i];
            (, uint256 precomputedUntilBlock) = precomputeDividendsAndRewards(
                holderStake
            );
            if (precomputedUntilBlock != currentBlockNumber) return false;
        }
        // TODO Refine, probably less
        if (gasleft() < 50000 + 20000 * stakes.length) {
            return false;
        }
        for (uint256 i = 0; i < stakes.length; ++i) {
            HolderStake storage holderStake = stakes[i];
            currentTotalPonderedStake -= holderStake.ponderedAmount;
            holderStake.ponderedAmount = computePonderedStakeAmount(
                holderStake.amount,
                holderStake.timeBonus,
                newSocialBonus
            );
            currentTotalPonderedStake += holderStake.ponderedAmount;
        }
        holderSocialBonus[holder] = newSocialBonus;
        return true;
    }

    function getHolderSocialBonus(address holder)
        external
        view
        returns (uint256)
    {
        return holderSocialBonus[holder];
    }

    struct SocialBonusBatchRow {
        address holderAddress;
        uint256 socialBonus;
    }

    function setSocialBonusBatch(SocialBonusBatchRow[] memory rows)
        external
        onlyOwner
        returns (uint256 processedCount)
    {
        bool stillHasGas = true;
        for (
            processedCount = 0;
            processedCount < rows.length && stillHasGas;
            ++processedCount
        ) {
            SocialBonusBatchRow memory row = rows[processedCount];
            stillHasGas = setHolderSocialBonus(
                row.holderAddress,
                row.socialBonus
            );
        }
    }

    function stake(uint256 amount, uint256 months) external {
        require(amount >= 1 ether, "Staking: Cannot stake less than 1 token");
        require(
            amount <= MAX_STAKE,
            "Staking: Cannot stake more than ~4B tokens"
        );
        require(months > 0 && months < 4, "Staking: 1, 2 or 3 months only");
        HolderStake[] storage stakes = holderStakes[msg.sender];
        require(stakes.length < 5, "Staking limited to 5 slots");

        uint256 timeBonus = findTimeBonus(months);

        uint256 ponderedAmount = computePonderedStakeAmount(
            amount,
            timeBonus,
            holderSocialBonus[msg.sender]
        );

        uint256 blockedUntil = block.timestamp + months * 30 days;

        stakes.push(
            HolderStake(
                amount,
                ponderedAmount,
                timeBonus,
                currentBlockNumber, // startBlock
                blockedUntil,
                currentBlockNumber, // precomputedUntilBlock
                0, // precomputedClaimableRewards
                0, // precomputedUnclaimableRewards
                0, // precomputedDividends
                0 // withdrawn
            )
        );
        currentTotalStake += amount;
        currentTotalPonderedStake += ponderedAmount;
        currentTotalOwnedPeuple += amount;
        uint256 allowance = IERC20(peuple).allowance(msg.sender, address(this));
        require(allowance >= amount, "Staking: check allowance");
        IERC20(peuple).transferFrom(msg.sender, address(this), amount);

        createNewBlock();
    }

    function computePonderedStakeAmount(
        uint256 amount,
        uint256 timeBonus,
        uint256 socialBonus
    ) internal pure returns (uint256) {
        return (amount * (100 + timeBonus + socialBonus)) / 100;
    }

    function restake(uint256 stakeIndex, uint256 months)
        external
        returns (bool)
    {
        require(months > 0 && months < 4, "Restaking: 1, 2 or 3 months only");
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        require(
            holderStake.blockedUntil < block.timestamp,
            "Restaking: stake still blocked"
        );
        (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 precomputedUntilBlock
        ) = precomputeDividendsAndRewards(holderStake);
        // TODO Refine (probably less)
        if (precomputedUntilBlock != currentBlockNumber || gasleft() < 80000)
            return false;
        uint256 newPonderedStakeAmount = computePonderedStakeAmount(
            holderStake.amount,
            findTimeBonus(months),
            holderSocialBonus[msg.sender]
        );
        uint256 recoveredRewards = computeRecoveredRewardsFor(
            holderStake.ponderedAmount,
            newPonderedStakeAmount,
            dividendsAndRewards.unclaimableRewards
        );

        currentTotalPonderedStake -= holderStake.ponderedAmount;
        currentTotalPonderedStake += newPonderedStakeAmount;
        holderStake.ponderedAmount = newPonderedStakeAmount;

        holderStake.blockedUntil = block.timestamp + months * 30 days;
        uint256 releasedRewards = holderStake.precomputedUnclaimableRewards -
            recoveredRewards;
        holderStake.precomputedClaimableRewards += recoveredRewards;
        currentTotalOwnedPeuple -= releasedRewards;
        holderStake.precomputedUnclaimableRewards = 0;
        return true;
    }

    function findTimeBonus(uint256 months)
        internal
        view
        returns (uint256 timeBonus)
    {
        timeBonus = 0;
        if (months == 2) {
            timeBonus = bonusForTwoMonthStaking;
        }
        if (months == 3) {
            timeBonus = bonusForThreeMonthStaking;
        }
    }

    function computeRecoveredRewards(uint256 stakeIndex, uint256 months)
        external
        view
        returns (uint256 recoveredRewards)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        uint256 newPonderedStakeAmount = computePonderedStakeAmount(
            holderStake.amount,
            findTimeBonus(months),
            holderSocialBonus[msg.sender]
        );
        DividendsAndRewards
            memory dividendsAndRewards = computeDividendsAndRewardsFailable(
                holderStake
            );
        return
            computeRecoveredRewardsFor(
                holderStake.ponderedAmount,
                newPonderedStakeAmount,
                dividendsAndRewards.unclaimableRewards
            );
    }

    function computeRecoveredRewardsFor(
        uint256 currentPonderedStakeAmount,
        uint256 newPonderedStakeAmount,
        uint256 unclaimableRewards
    ) internal pure returns (uint256) {
        if (newPonderedStakeAmount >= currentPonderedStakeAmount) {
            return unclaimableRewards;
        }
        return
            (unclaimableRewards * newPonderedStakeAmount) /
            currentPonderedStakeAmount;
    }

    function unstake(uint256 stakeIndex) external returns (uint256) {
        HolderStake[] storage stakes = holderStakes[msg.sender];
        HolderStake storage holderStake = stakes[stakeIndex];
        if (holderStake.blockedUntil < block.timestamp) {
            DividendsAndRewards
                memory dividendsAndRewards = computeDividendsAndRewardsFailable(
                    holderStake
                );
            uint256 amountToWithdraw = holderStake.amount +
                claimable(dividendsAndRewards) -
                holderStake.withdrawn;
            currentTotalStake -= holderStake.amount;
            currentTotalPonderedStake -= holderStake.ponderedAmount;
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

    function computeHolderTotalStakeAmount() external view returns (uint256) {
        HolderStake[] storage stakes = holderStakes[msg.sender];
        uint256 total = 0;
        for (uint256 i = 0; i < stakes.length; ++i) {
            total += stakes[i].amount;
        }
        return total;
    }

    function computeDividends(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            computeDividendsAndRewardsFailable(
                holderStakes[msg.sender][stakeIndex]
            ).dividends;
    }

    function computeRewards(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            computeDividendsAndRewardsFailable(
                holderStakes[msg.sender][stakeIndex]
            ).claimableRewards;
    }

    function computeDividendsAndRewards(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            claimable(
                computeDividendsAndRewardsFailable(
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
            claimable(
                computeDividendsAndRewardsFailable(
                    holderStakes[msg.sender][stakeIndex]
                )
            ) - holderStake.withdrawn;
    }

    function computeDividendsAndRewardsFailable(HolderStake storage holderStake)
        internal
        view
        returns (DividendsAndRewards memory)
    {
        (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 computedUntilBlock
        ) = computeDividendsAndRewardsFor(holderStake);
        require(computedUntilBlock == currentBlockNumber, "Not enough gas");
        return dividendsAndRewards;
    }

    function computeDividendsAndRewardsFor(HolderStake storage holderStake)
        internal
        view
        returns (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 computedUntilBlock
        )
    {
        dividendsAndRewards = DividendsAndRewards(
            holderStake.precomputedDividends,
            holderStake.precomputedClaimableRewards,
            holderStake.precomputedUnclaimableRewards
        );
        for (
            computedUntilBlock = holderStake.precomputedUntilBlock;
            computedUntilBlock < currentBlockNumber &&
                gasleft() > minimumGasForBlockComputation;
            ++computedUntilBlock
        ) {
            DayBlock storage focusedBlock = dayBlocks[computedUntilBlock];
            dividendsAndRewards.dividends +=
                (focusedBlock.dividends * holderStake.amount) /
                focusedBlock.totalStake;
            uint256 rewards = (focusedBlock.rewards *
                holderStake.ponderedAmount) / focusedBlock.totalPonderedStake;
            if (focusedBlock.creationTime > holderStake.blockedUntil) {
                // expired
                dividendsAndRewards.unclaimableRewards += rewards;
            } else {
                dividendsAndRewards.claimableRewards += rewards;
            }
        }
    }

    function precomputeDividendsAndRewards(HolderStake storage holderStake)
        internal
        returns (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 precomputedUntilBlock
        )
    {
        (
            dividendsAndRewards,
            precomputedUntilBlock
        ) = computeDividendsAndRewardsFor(holderStake);
        holderStake.precomputedDividends = dividendsAndRewards.dividends;
        holderStake.precomputedClaimableRewards = dividendsAndRewards
            .claimableRewards;
        holderStake.precomputedUnclaimableRewards = dividendsAndRewards
            .unclaimableRewards;
        holderStake.precomputedUntilBlock = precomputedUntilBlock;
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
        (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 precomputedUntilBlock
        ) = precomputeDividendsAndRewards(holderStake);
        if (
            precomputedUntilBlock != currentBlockNumber ||
            // TODO Refine
            gasleft() < minimumGasForPeupleTransfer
        ) return 0;
        uint256 amountToWithdraw = claimable(dividendsAndRewards) -
            holderStake.withdrawn;
        holderStake.withdrawn += amountToWithdraw;
        currentTotalOwnedPeuple -= amountToWithdraw;
        IERC20(peuple).transfer(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    function stakeDividendsAndRewards(uint256 stakeIndex)
        external
        returns (uint256)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 precomputedUntilBlock
        ) = precomputeDividendsAndRewards(holderStake);
        if (
            precomputedUntilBlock != currentBlockNumber ||
            // TODO Refine
            gasleft() < 50000
        ) return 0;
        uint256 amountToStake = claimable(dividendsAndRewards) -
            holderStake.withdrawn;
        holderStake.withdrawn += amountToStake;
        holderStake.amount += amountToStake;
        currentTotalStake += amountToStake;
        currentTotalPonderedStake -= holderStake.ponderedAmount;
        holderStake.ponderedAmount = computePonderedStakeAmount(
            holderStake.amount,
            holderStake.timeBonus,
            holderSocialBonus[msg.sender]
        );
        currentTotalPonderedStake += holderStake.ponderedAmount;
        return amountToStake;
    }

    function swapCakeForTokens(uint256 amount) internal returns (uint256) {
        IERC20(cake).approve(address(swapPool), amount);
        return swapPool.convertCakeIntoPeuple(address(this), amount);
    }

    function computeHolderStakeInfo(address holder, uint256 stakeIndex)
        external
        view
        returns (
            uint256 stakeAmount,
            uint256 ponderedStakeAmount,
            uint256 timeBonus,
            uint256 startBlock,
            uint256 blockedUntil,
            uint256 computedUntilBlock,
            uint256 dividends,
            uint256 claimableRewards,
            uint256 unclaimableRewards,
            uint256 withdrawn
        )
    {
        HolderStake storage holderStake = holderStakes[holder][stakeIndex];
        stakeAmount = holderStake.amount;
        ponderedStakeAmount = holderStake.ponderedAmount;
        timeBonus = holderStake.timeBonus;
        startBlock = holderStake.startBlock;
        blockedUntil = holderStake.blockedUntil;
        (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 untilBlock
        ) = computeDividendsAndRewardsFor(holderStake);
        computedUntilBlock = untilBlock;
        dividends = dividendsAndRewards.dividends;
        claimableRewards = dividendsAndRewards.claimableRewards;
        unclaimableRewards = dividendsAndRewards.unclaimableRewards;
        withdrawn = holderStake.withdrawn;
    }
}
