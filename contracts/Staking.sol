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

    uint256 public currentTotalStake = 0; // TODO update on unstake
    uint256 public currentTotalPonderedStake = 0; // TODO update on unstake
    uint256 public currentTotalOwnedPeuple = 0; // TODO update on unstake

    uint256 public percentBonusForTwoMonthStaking = 50; // TODO setter
    uint256 public percentBonusForThreeMonthStaking = 100; // TODO setter

    struct HolderStake {
        uint256 amount;
        uint256 timeBonusPonderedAmount;
        uint256 startBlock;
        uint256 blockedUntil;
        uint256 precomputedUntilBlock;
        uint256 precomputedRewards;
        uint256 precomputedDividends;
        uint256 withdrawn;
    }

    struct HolderSocial {
        uint256 blockNumber;
        uint256 percentBonus;
    }

    struct DayBlock {
        uint256 totalStake;
        uint256 totalPonderedStake;
        uint256 dividends;
        uint256 rewards;
    }

    mapping(uint256 => DayBlock) public dayBlocks;
    mapping(uint256 => uint256) public blockCreationTime;

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

    function setPercentBonusForTwoMonthStaking(uint256 bonus) public onlyOwner {
        require(bonus <= 100, "Staking: bonus for 2 months <= 100");
        percentBonusForTwoMonthStaking = bonus;
    }

    function setPercentBonusForThreeMonthStaking(uint256 bonus)
        public
        onlyOwner
    {
        require(bonus <= 200, "Staking: bonus for 3 months <= 200");
        percentBonusForThreeMonthStaking = bonus;
    }

    function setHolderSocialPercentBonus(address staker, uint256 bonus)
        public
        onlyOwner
    {
        // TODO delete all outdated socials (also take into account precomputations, no need to keep it if it's already precomputed)
        require(bonus <= 200, "Staking: social bonus <= 200");
        HolderSocial[] storage socials = holderSocials[staker];
        ensureHolderSocialsInitialized(socials);
        HolderSocial storage currentSocial = socials[socials.length - 1];
        require(currentSocial.percentBonus != bonus, "Staking: same bonus");
        uint256 currentHolderPonderedStake = computePonderedStakeFor(
            holderStakes[staker],
            currentSocial.percentBonus
        );
        if (currentSocial.blockNumber == currentBlockNumber) {
            currentSocial.percentBonus = bonus;
        } else {
            socials.push(HolderSocial(currentBlockNumber, bonus));
        }
        currentTotalPonderedStake -= currentHolderPonderedStake;
        currentTotalPonderedStake += computePonderedStakeFor(
            holderStakes[staker],
            bonus
        );
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
                0, // precomputedRewards
                0, //precomputedDividends
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

    function unstake(uint256 stakeIndex) external returns (uint256) {
        createNewBlock();

        HolderStake[] storage stakes = holderStakes[msg.sender];
        HolderStake storage holderStake = stakes[stakeIndex];
        if (holderStake.blockedUntil < block.timestamp) {
            uint256 allDividendsAndRewards = computeHolderDividendsAndRewardsForStake( // TODO optimize by passing stake directly
                stakeIndex
            );
            uint256 amountToWithdraw = holderStake.amount +
                allDividendsAndRewards -
                holderStake.withdrawn;
            currentTotalStake -= holderStake.amount;
            HolderSocial[] storage socials = holderSocials[msg.sender];
            HolderSocial storage currentSocial = socials[socials.length - 1];
            currentTotalPonderedStake -=
                holderStake.amount +
                (holderStake.amount * currentSocial.percentBonus) /
                100;
            currentTotalOwnedPeuple -= amountToWithdraw;
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
        return computeStakeFor(stakes);
    }

    function computeStakeFor(
        HolderStake[] memory stakes // storage ??
    ) internal pure returns (uint256) {
        uint256 arrayLength = stakes.length;
        uint256 total = 0;
        for (uint256 i = 0; i < arrayLength; i++) {
            total += stakes[i].amount;
        }
        return total;
    }

    function computePonderedStakeFor(
        HolderStake[] memory stakes, // storage ??
        uint256 socialBonus
    ) internal pure returns (uint256) {
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

    function computeHolderDividends() external view returns (uint256) {
        return
            computeHolderDividendsOrRewardsOrBoth(
                DividendsOrRewardsOrBoth.Dividends,
                holderStakes[msg.sender],
                holderSocials[msg.sender]
            );
    }

    function computeHolderRewards() external view returns (uint256) {
        return
            computeHolderDividendsOrRewardsOrBoth(
                DividendsOrRewardsOrBoth.Rewards,
                holderStakes[msg.sender],
                holderSocials[msg.sender]
            );
    }

    function computeHolderDividendsAndRewards() public view returns (uint256) {
        return
            computeHolderDividendsOrRewardsOrBoth(
                DividendsOrRewardsOrBoth.Both,
                holderStakes[msg.sender],
                holderSocials[msg.sender]
            );
    }

    function computeHolderDividendsForStake(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            computeHolderDividendsOrRewardsOrBothForStakeIndex(
                DividendsOrRewardsOrBoth.Dividends,
                stakeIndex
            );
    }

    function computeHolderRewardsForStake(uint256 stakeIndex)
        external
        view
        returns (uint256)
    {
        return
            computeHolderDividendsOrRewardsOrBothForStakeIndex(
                DividendsOrRewardsOrBoth.Rewards,
                stakeIndex
            );
    }

    // TODO make external ?
    function computeHolderDividendsAndRewardsForStake(uint256 stakeIndex)
        public
        view
        returns (uint256)
    {
        return
            computeHolderDividendsOrRewardsOrBothForStakeIndex(
                DividendsOrRewardsOrBoth.Both,
                stakeIndex
            );
    }

    function computeHolderDividendsOrRewardsOrBothForStakeIndex(
        DividendsOrRewardsOrBoth filter,
        uint256 stakeIndex
    ) internal view returns (uint256) {
        HolderStake[] memory stakes = new HolderStake[](1);
        stakes[stakeIndex] = holderStakes[msg.sender][stakeIndex];
        return
            computeHolderDividendsOrRewardsOrBoth(
                filter,
                stakes,
                holderSocials[msg.sender]
            );
    }

    function computeHolderDividendsOrRewardsOrBoth(
        DividendsOrRewardsOrBoth filter,
        HolderStake[] memory activeStakes,
        HolderSocial[] memory socials
    ) internal view returns (uint256) {
        // TODO test when not a staker
        uint256 result = 0;
        (activeStakes, result) = getPrecomputedRewardsAndDividends(
            filter,
            activeStakes
        );
        uint256 activeStakeCount = activeStakes.length;
        uint256 socialIndex = socials.length - 1;
        HolderSocial memory social = socials[socialIndex];
        for (
            uint256 previousBlockNumber = currentBlockNumber;
            activeStakeCount > 0 && previousBlockNumber > 0;
            previousBlockNumber--
        ) {
            uint256 focusedBlockNumber = previousBlockNumber - 1;
            DayBlock storage focusedBlock = dayBlocks[focusedBlockNumber]; // memory ??

            // find relevant social bonus block
            while (social.blockNumber > focusedBlockNumber) {
                socialIndex--;
                social = socials[socialIndex];
            }

            // recompute active stakes
            uint256 newActiveStakeCount = 0;
            HolderStake[] memory newActiveStakes = new HolderStake[](
                activeStakeCount
            );
            for (
                uint256 stakeIndex = 0;
                stakeIndex < activeStakeCount;
                stakeIndex++
            ) {
                HolderStake memory focusedStake = activeStakes[stakeIndex];
                if (focusedStake.startBlock <= focusedBlockNumber) {
                    newActiveStakeCount++;
                    newActiveStakes[stakeIndex] = focusedStake;

                    if (filter != DividendsOrRewardsOrBoth.Rewards) {
                        result +=
                            (focusedBlock.dividends * focusedStake.amount) /
                            focusedBlock.totalStake;
                    }
                    if (filter != DividendsOrRewardsOrBoth.Dividends) {
                        // Base rewards + time bonus
                        result +=
                            (focusedBlock.rewards *
                                focusedStake.timeBonusPonderedAmount) /
                            focusedBlock.totalPonderedStake;
                        // Social bonus
                        result +=
                            (focusedBlock.rewards *
                                focusedStake.amount *
                                social.percentBonus) /
                            (focusedBlock.totalPonderedStake * 100);
                    }
                }
            }
            activeStakeCount = newActiveStakeCount;
            activeStakes = newActiveStakes;
        }
        return result;
    }

    function getPrecomputedRewardsAndDividends(
        DividendsOrRewardsOrBoth filter,
        HolderStake[] memory stakes
    ) internal view returns (HolderStake[] memory, uint256) {
        uint256 result = 0;
        HolderStake[] memory notPrecomputedStakes = new HolderStake[](
            stakes.length
        );
        uint256 notPrecomputedStakesCount = 0;
        for (uint256 i = 0; i < stakes.length; i++) {
            HolderStake memory focusedStake = stakes[i];
            if (focusedStake.precomputedUntilBlock != currentBlockNumber) {
                notPrecomputedStakes[notPrecomputedStakesCount] = focusedStake;
                notPrecomputedStakesCount++;
            } else {
                if (filter != DividendsOrRewardsOrBoth.Rewards) {
                    result += focusedStake.precomputedDividends;
                }
                if (filter != DividendsOrRewardsOrBoth.Dividends) {
                    result += focusedStake.precomputedRewards;
                }
            }
        }
        HolderStake[] memory returnedStakes = new HolderStake[](
            notPrecomputedStakesCount
        );
        for (uint256 i = 0; i < notPrecomputedStakesCount; i++) {
            returnedStakes[i] = notPrecomputedStakes[i];
        }
        return (returnedStakes, result);
    }

    function precomputeAllRewardsAndDividends() external returns (bool) {
        return precomputeRewardsAndDividendsForStakes(holderStakes[msg.sender]);
    }

    function precomputeRewardsAndDividendsForStake(uint256 stakeIndex)
        external
        returns (bool)
    {
        return
            precomputeRewardsAndDividends(holderStakes[msg.sender][stakeIndex]);
    }

    function precomputeRewardsAndDividendsForStakes(
        HolderStake[] storage stakes
    ) internal returns (bool) {
        bool hasGasLeft = true;
        for (uint256 stakeIndex = 0; stakeIndex < stakes.length; stakeIndex++) {
            HolderStake storage focusedStake = holderStakes[msg.sender][
                stakeIndex
            ];
            hasGasLeft = precomputeRewardsAndDividends(focusedStake);
            if (hasGasLeft == false) {
                return false;
            }
        }
        return true;
    }

    function precomputeRewardsAndDividends(HolderStake storage holderStake)
        internal
        returns (bool)
    {
        HolderSocial[] memory socials = holderSocials[msg.sender];
        uint256 socialIndex = 0;
        HolderSocial memory social = socials[socialIndex];
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

            // Base rewards + time bonus
            holderStake.precomputedRewards +=
                (focusedBlock.rewards * holderStake.timeBonusPonderedAmount) /
                focusedBlock.totalPonderedStake;

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
            holderStake.precomputedRewards +=
                (focusedBlock.rewards *
                    holderStake.amount *
                    social.percentBonus) /
                (focusedBlock.totalPonderedStake * 100);

            holderStake.precomputedUntilBlock++;
            if (gasleft() < 70000) return false;
        }
        return true;
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
            currentTotalStake,
            currentTotalPonderedStake,
            dividends,
            rewards
        );
        blockCreationTime[currentBlockNumber] = currentBlockCreationTime;
        currentTotalOwnedPeuple += dividends + rewards;
        currentBlockCreationTime = block.timestamp;
        currentBlockNumber += 1;
        currentBlockCakeRewards = 0;
    }

    function withdrawAllRewardsAndDividends() external returns (uint256) {
        HolderStake[] storage stakes = holderStakes[msg.sender];
        bool precomputed = precomputeRewardsAndDividendsForStakes(stakes);
        if (!precomputed) return 0;
        uint256 amountToWithdraw = 0;
        for (uint256 stakeIndex = 0; stakeIndex < stakes.length; stakeIndex++) {
            HolderStake storage holderStake = stakes[stakeIndex];
            uint256 allDividendsAndRewards = computeHolderDividendsAndRewardsForStake(
                stakeIndex // TODO optimize by passing stake directly
            );
            amountToWithdraw += allDividendsAndRewards - holderStake.withdrawn;
            holderStake.withdrawn = allDividendsAndRewards;
        }
        currentTotalOwnedPeuple -= amountToWithdraw;
        IERC20(peuple).transfer(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    function withdrawRewardsAndDividends(uint256 stakeIndex)
        external
        returns (uint256)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        bool precomputed = precomputeRewardsAndDividends(holderStake);
        if (!precomputed) return 0;
        uint256 allDividendsAndRewards = computeHolderDividendsAndRewardsForStake(
            stakeIndex // TODO optimize by passing stake directly
        );
        uint256 amountToWithdraw = allDividendsAndRewards -
            holderStake.withdrawn;
        holderStake.withdrawn = allDividendsAndRewards;
        currentTotalOwnedPeuple -= amountToWithdraw;
        IERC20(peuple).transfer(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    function swapCakeForTokens(uint256 amount) internal returns (uint256) {
        IERC20(cake).approve(address(swapPool), amount);
        return swapPool.convertCakeIntoPeuple(address(this), amount);
    }
}
