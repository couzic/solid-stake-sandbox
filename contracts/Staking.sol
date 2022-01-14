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

    struct HolderSocial {
        uint256 blockNumber;
        uint256 percentBonus;
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

    mapping(address => HolderSocial[]) public holderSocials;

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

    function setHolderSocialPercentBonus(address staker, uint256 bonus)
        external
        onlyOwner
    {
        // TODO delete all outdated socials (also take into account precomputations, no need to keep it if it's already precomputed)
        require(bonus <= 200, "Staking: social bonus <= 200");
        HolderSocial[] storage socials = holderSocials[staker];
        ensureHolderSocialsInitialized(socials);
        HolderSocial storage currentSocial = socials[socials.length - 1];
        require(currentSocial.percentBonus != bonus, "Staking: same bonus");
        HolderStake[] storage stakes = holderStakes[staker];
        uint256 currentHolderPonderedStake = computePonderedStakeFor(
            stakes,
            currentSocial.percentBonus
        );
        if (currentSocial.blockNumber == currentBlockNumber) {
            currentSocial.percentBonus = bonus;
        } else {
            socials.push(HolderSocial(currentBlockNumber, bonus));
        }
        currentTotalPonderedStake -= currentHolderPonderedStake;
        currentTotalPonderedStake += computePonderedStakeFor(stakes, bonus);
    }

    function ensureHolderSocialsInitialized(HolderSocial[] storage socials)
        internal
    {
        if (socials.length == 0) {
            socials.push(HolderSocial(0, 0));
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
        require(stakes.length < 20, "Staking limited to 20 slots");

        uint256 timeBonusPonderedAmount = amount;
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
        currentTotalStake += amount;
        currentTotalPonderedStake += timeBonusPonderedAmount;
        currentTotalOwnedPeuple += amount;
        uint256 allowance = IERC20(peuple).allowance(msg.sender, address(this));
        require(allowance >= amount, "Staking: check allowance");
        IERC20(peuple).transferFrom(msg.sender, address(this), amount);

        ensureHolderSocialsInitialized(holderSocials[msg.sender]);

        createNewBlock();
    }

    // TODO Restake
    function unstake(uint256 stakeIndex) external returns (uint256) {
        createNewBlock();

        HolderStake[] storage stakes = holderStakes[msg.sender];
        HolderStake storage holderStake = stakes[stakeIndex];
        if (holderStake.blockedUntil < block.timestamp) {
            DividendsAndRewards memory dividendsAndRewards = computeDividendsOrRewardsOrBoth( // TODO optimize by passing stake directly
                DividendsOrRewardsOrBoth.Both,
                stakeIndex
            );
            uint256 amountToWithdraw = holderStake.amount +
                dividendsAndRewards.claimable -
                holderStake.withdrawn;
            currentTotalStake -= holderStake.amount;
            HolderSocial[] storage socials = holderSocials[msg.sender];
            HolderSocial storage currentSocial = socials[socials.length - 1];
            currentTotalPonderedStake -=
                holderStake.amount +
                (holderStake.amount * currentSocial.percentBonus) /
                100;
            currentTotalOwnedPeuple -= amountToWithdraw;
            currentTotalOwnedPeuple -= dividendsAndRewards.unclaimable;
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

    function computePonderedStakeFor(
        HolderStake[] storage stakes,
        uint256 socialBonus
    ) internal view returns (uint256) {
        uint256 arrayLength = stakes.length;
        uint256 total = 0;
        for (uint256 i = 0; i < arrayLength; i++) {
            total += stakes[i].timeBonusPonderedAmount;
            total += (stakes[i].amount * socialBonus) / 100;
        }
        return total;
    }

    enum DividendsOrRewardsOrBoth {
        Dividends,
        Rewards,
        Both
    }

    function computeDividends(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            computeClaimableDividendsOrRewardsOrBoth(
                DividendsOrRewardsOrBoth.Dividends,
                stakeIndex
            );
    }

    function computeRewards(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            computeClaimableDividendsOrRewardsOrBoth(
                DividendsOrRewardsOrBoth.Rewards,
                stakeIndex
            );
    }

    function computeDividendsAndRewards(uint256 stakeIndex)
        public
        view
        returns (uint256)
    {
        return
            computeClaimableDividendsOrRewardsOrBoth(
                DividendsOrRewardsOrBoth.Both,
                stakeIndex
            );
    }

    function computeWithdrawableDividendsAndRewards(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        uint256 claimable = computeDividendsAndRewards(stakeIndex);
        // TODO use directly storage stake
        return claimable - holderStakes[msg.sender][stakeIndex].withdrawn;
    }

    struct DividendsAndRewards {
        uint256 claimable;
        uint256 unclaimable;
    }

    function computeClaimableDividendsOrRewardsOrBoth(
        DividendsOrRewardsOrBoth filter,
        uint256 stakeIndex
    ) internal view returns (uint256) {
        DividendsAndRewards memory result = computeDividendsOrRewardsOrBoth(
            filter,
            stakeIndex
        );
        return result.claimable;
    }

    function computeDividendsOrRewardsOrBoth(
        DividendsOrRewardsOrBoth filter,
        uint256 stakeIndex
    ) internal view returns (DividendsAndRewards memory) {
        // TODO test when not a staker
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        uint256 claimable = holderStake.precomputedDividends +
            holderStake.precomputedClaimableRewards;
        uint256 unclaimable = holderStake.precomputedUnclaimableRewards;
        HolderSocial[] storage socials = holderSocials[msg.sender];
        uint256 socialIndex = socials.length - 1;
        HolderSocial memory social = socials[socialIndex];
        for (
            uint256 previousBlockNumber = currentBlockNumber;
            previousBlockNumber > holderStake.precomputedUntilBlock &&
                previousBlockNumber > holderStake.startBlock &&
                previousBlockNumber > 0;
            previousBlockNumber--
        ) {
            uint256 focusedBlockNumber = previousBlockNumber - 1;
            DayBlock storage focusedBlock = dayBlocks[focusedBlockNumber]; // memory ??
            // find relevant social bonus block
            while (social.blockNumber > focusedBlockNumber) {
                socialIndex--;
                social = socials[socialIndex];
            }

            if (filter != DividendsOrRewardsOrBoth.Rewards) {
                claimable +=
                    (focusedBlock.dividends * holderStake.amount) /
                    focusedBlock.totalStake;
            }
            if (filter != DividendsOrRewardsOrBoth.Dividends) {
                // Base rewards + time bonus
                uint256 rewards = (focusedBlock.rewards *
                    holderStake.timeBonusPonderedAmount) /
                    focusedBlock.totalPonderedStake;
                // Social bonus
                rewards +=
                    (focusedBlock.rewards *
                        holderStake.amount *
                        social.percentBonus) /
                    (focusedBlock.totalPonderedStake * 100);
                if (focusedBlock.creationTime > holderStake.blockedUntil) {
                    // expired
                    unclaimable += rewards;
                } else {
                    claimable += rewards;
                }
            }
        }
        return DividendsAndRewards(claimable, unclaimable);
    }

    function precomputeRewardsAndDividends(HolderStake storage holderStake)
        internal
        returns (bool)
    {
        HolderSocial[] storage socials = holderSocials[msg.sender];
        uint256 socialIndex = 0;
        HolderSocial storage social = socials[socialIndex];
        uint256 blockWithNextSocialIndex = currentBlockNumber;
        if (socialIndex + 1 < socials.length) {
            blockWithNextSocialIndex = socials[socialIndex + 1].blockNumber;
        }
        while (holderStake.precomputedUntilBlock < currentBlockNumber) {
            DayBlock storage focusedBlock = dayBlocks[
                holderStake.precomputedUntilBlock
            ];

            // Dividends
            holderStake.precomputedDividends +=
                (focusedBlock.dividends * holderStake.amount) /
                focusedBlock.totalStake;

            // Social bonus
            while (
                holderStake.precomputedUntilBlock == blockWithNextSocialIndex
            ) {
                socialIndex++;
                social = socials[socialIndex];
                if (socialIndex + 1 == socials.length) {
                    blockWithNextSocialIndex = currentBlockNumber;
                } else {
                    blockWithNextSocialIndex = socials[socialIndex + 1]
                        .blockNumber;
                }
            }

            // Base rewards + time bonus
            uint256 rewards = (focusedBlock.rewards *
                holderStake.timeBonusPonderedAmount) /
                focusedBlock.totalPonderedStake;
            // Social bonus rewards
            rewards +=
                (focusedBlock.rewards *
                    holderStake.amount *
                    social.percentBonus) /
                (focusedBlock.totalPonderedStake * 100);
            if (focusedBlock.creationTime > holderStake.blockedUntil) {
                // expired
                holderStake.precomputedUnclaimableRewards += rewards;
            } else {
                holderStake.precomputedClaimableRewards += rewards;
            }
            holderStake.precomputedUntilBlock++;
            if (gasleft() < 70000) return false; // enough gas for another block
        }
        return gasleft() > 400000; // enough gas for transfer
    }

    function canCreateNewBlock() public view returns (bool) {
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

    function withdrawRewardsAndDividends(uint256 stakeIndex)
        external
        returns (uint256)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        bool precomputed = precomputeRewardsAndDividends(holderStake);
        if (!precomputed) return 0;
        DividendsAndRewards memory dividendsAndRewards = computeDividendsOrRewardsOrBoth(
            DividendsOrRewardsOrBoth.Both,
            stakeIndex // TODO optimize by passing stake directly
        );
        uint256 amountToWithdraw = dividendsAndRewards.claimable -
            holderStake.withdrawn;
        holderStake.withdrawn = dividendsAndRewards.claimable;
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
