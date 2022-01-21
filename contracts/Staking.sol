// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HitchensUnorderedAddressSet.sol";
import "./OwnableStaking.sol";
import "./PausableStaking.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";

import "./IUniswapV2Pair.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router.sol";

contract Staking is Ownable, Pausable, ReentrancyGuard {
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

    struct DividendsAndRewards {
        uint256 dividends;
        uint256 claimableRewards;
        uint256 unclaimableRewards;
    }
    
    event Stake(address staker, uint256 amount, uint256 duration);
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

    function setHolderSocialPercentBonus(address staker, uint256 bonus)
        external
        onlyPusher
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

    function ensureHolderSocialsInitialized(HolderSocial[] storage socials)
        internal
    {
        if (socials.length == 0) {
            socials.push(HolderSocial(0, 0));
        }
    }

    function stake(uint256 amount, uint256 months) whenNotPaused external {
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
        require(allowance >= amount, "Staking: check the PEUPLE allowance"); 
        IERC20(peuple).transferFrom(msg.sender, address(this), amount);

        emit Stake(msg.sender, amount, months);

        ensureHolderSocialsInitialized(holderSocials[msg.sender]);

        createNewBlock();
    }

    // TODO Restake
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
            HolderSocial[] storage socials = holderSocials[msg.sender];
            HolderSocial storage currentSocial = socials[socials.length - 1];
            currentTotalPonderedStake -=
                holderStake.amount +
                (holderStake.amount * currentSocial.percentBonus) /
                100;
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
        uint256 allowance = IERC20(cake).allowance(msg.sender, address(this));
        require(allowance >= cakeRewards, "Staking: check the CAKE allowance"); 

        IERC20(cake).transferFrom(msg.sender, address(this), cakeRewards);
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
        HolderSocial[] storage socials = holderSocials[msg.sender];
        uint256 socialIndex = socials.length - 1;
        HolderSocial storage social = socials[socialIndex];
        for (
            uint256 previousBlockNumber = currentBlockNumber;
            previousBlockNumber > holderStake.precomputedUntilBlock &&
                previousBlockNumber > holderStake.startBlock &&
                previousBlockNumber > 0;
            previousBlockNumber--
        ) {
            uint256 focusedBlockNumber = previousBlockNumber - 1;
            DayBlock storage focusedBlock = dayBlocks[focusedBlockNumber];
            // Find relevant social bonus
            while (social.blockNumber > focusedBlockNumber) {
                socialIndex--;
                social = socials[socialIndex];
            }

            dividends +=
                (focusedBlock.dividends * holderStake.amount) /
                focusedBlock.totalStake;
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

    function precomputeRewardsAndDividends(HolderStake storage holderStake)
        internal
        returns (bool)
    {
        HolderSocial[] storage socials = holderSocials[msg.sender];
        uint256 socialIndex = 0;
        HolderSocial storage social = socials[socialIndex];
        uint256 blockWithNextSocialIndex = currentBlockNumber;
        if (socials.length > 1) {
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

            // Find relevant social bonus
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

        function withdrawRewardsAndDividends(uint256 stakeIndex)
        external
        returns (uint256)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        bool precomputed = precomputeRewardsAndDividends(holderStake);
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

    function emptyStaking() external onlyOwner { // TODO whenPausedLongEnough
        IERC20(peuple).transfer(msg.sender, IERC20(peuple).balanceOf(address(this)));
        IERC20(cake).transfer(msg.sender, IERC20(cake).balanceOf(address(this)));
        
        emit StakingEnded();
    }
}