// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./HitchensUnorderedAddressSet.sol";
import "./OwnableStaking.sol";
import "./PausableStaking.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "hardhat/console.sol";

import "./IUniswapV2Pair.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router.sol";

contract Staking is Ownable, Pausable {

    using SafeERC20 for IERC20;

    uint256 public currentBlockCreationTime = block.timestamp;
    uint256 public currentBlockNumber = 0;
    uint256 public minimumBlockAge = 1 days;
    uint256 private currentBlockCakeRewards = 0;

    address public peuple = address(0x0Bcc37174f0f322b8b9c81b5C51c90B49e5669Be);
    address public cake = address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    IUniswapV2Router02 public uniswapV2Router;

    uint256 public minimumCakeForSwap = 10 ether;
    uint256 public minimumPeupleForBlockCreation = 10e6 ether;

    uint256 public currentTotalStake = 0;
    uint256 public currentTotalPonderedStake = 0;
    uint256 public currentTotalOwnedPeuple = 0;

    uint256 public bonusForTwoMonthStaking = 50;
    uint256 public bonusForThreeMonthStaking = 100;

    uint256 public minimumGasForBlockComputation = 70000;
    uint256 public minimumGasForPeupleTransfer = 400000;

    bool public canWithdrawAsCake = true;
    bool public decommissioned = false;
    uint256 public decommissionTime;

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
    
    event Stake(address staker, uint256 amount, uint256 duration);
    event Restake(address staker, uint duration);
    event Unstake(address staker, uint256 amount);
    event Swap(uint256 cake, uint256 peuple);
    event NewBlock(uint256 id, uint256 time);
    event RewardsReceived(uint cake);
    event StakingEnded();

    constructor() Pausable() {
        uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    }

    function setUniswapRouter(address _uniswapRouter) external onlyOwner {
        uniswapV2Router = IUniswapV2Router02(_uniswapRouter);
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
        onlyPusher
        returns (bool)
    {
        if (newSocialBonus == holderSocialBonus[holder]) return true;
        require(newSocialBonus <= 200, "Staking: social bonus <= 200");
        HolderStake[] storage stakes = holderStakes[holder];
        for (uint256 i = 0; i < stakes.length; ++i) {
            HolderStake storage holderStake = stakes[i];
            (, uint256 precomputedUntilBlock) = precomputeDividendsAndRewards(
                holderStake
            );
            if (precomputedUntilBlock != currentBlockNumber) return false;
        }
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

    function setCanWithdrawAsCake (bool _canWithdrawAsCake) external onlyOwner {
        canWithdrawAsCake = _canWithdrawAsCake;
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

    function setMinimumGasForPeupleTransfer(uint256 _minimumGasForPeupleTransfer) external onlyOwner {
        minimumGasForPeupleTransfer = _minimumGasForPeupleTransfer;
    }

    function setminimumGasForBlockComputation(uint256 _minimumGasForBlockComputation) external onlyOwner {
        require(_minimumGasForBlockComputation > 60000, "At least 60 000");
        minimumGasForBlockComputation = _minimumGasForBlockComputation;
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
        onlyPusher
        returns (uint256)
    {
        uint256 processedCount = 0;
        bool stillHasGas = true;
        while (processedCount < rows.length && stillHasGas) {
            SocialBonusBatchRow memory row = rows[processedCount];
            stillHasGas = setHolderSocialBonus(
                row.holderAddress,
                row.socialBonus
            );
            if (stillHasGas) {
                ++processedCount;
            }
        }
        return processedCount;
    }

    function stake(uint256 amount, uint256 months) external whenNotPaused {
        require(amount >= 1 ether, "Staking: Cannot stake less than 1 token");
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
        transferPeupleFrom(msg.sender, address(this), amount);

        emit Stake(msg.sender, amount, months);
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
        whenNotPaused
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
        if (precomputedUntilBlock != currentBlockNumber || gasleft() < 60000)
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
        emit Restake(msg.sender, months);
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

    function unstake(uint256 stakeIndex) external whenNotPaused returns (uint256) {
        HolderStake[] storage stakes = holderStakes[msg.sender];
        HolderStake storage holderStake = stakes[stakeIndex];
        if (holderStake.blockedUntil < block.timestamp || decommissioned) {
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
            transferPeuple(msg.sender, amountToWithdraw);
            return amountToWithdraw;
        } else {
            return 0;
        }
    }

    function sendCakeRewards(uint256 cakeRewards) external {
        transferCakeFrom(msg.sender, address(this), cakeRewards);
        currentBlockCakeRewards += cakeRewards;

        emit RewardsReceived(cakeRewards);
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
        public
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
        if (currentBlockAge < minimumBlockAge || currentTotalStake == 0) return false;
        uint256 cakeBalance = IERC20(cake).balanceOf(address(this));
        if (cakeBalance >= minimumCakeForSwap) return true;
        uint256 peupleBalance = IERC20(peuple).balanceOf(address(this));
        uint256 peupleRewardsInCurrentBlock = peupleBalance -
            currentTotalOwnedPeuple;
        return peupleRewardsInCurrentBlock >= minimumPeupleForBlockCreation;
    }

    function createNewBlock() public whenNotPaused {
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
            swappedPeuple = swapCakeForPeuple(cakeBalance);
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
        whenNotPaused
        returns (uint256)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 precomputedUntilBlock
        ) = precomputeDividendsAndRewards(holderStake);
        if (
            precomputedUntilBlock != currentBlockNumber ||
            gasleft() < minimumGasForPeupleTransfer
        ) return 0;
        uint256 amountToWithdraw = claimable(dividendsAndRewards) -
            holderStake.withdrawn;
        holderStake.withdrawn += amountToWithdraw;
        currentTotalOwnedPeuple -= amountToWithdraw;
        transferPeuple(msg.sender, amountToWithdraw);
        return amountToWithdraw;
    }

    function withdrawDividendsAndRewardsAsCake(uint256 stakeIndex)
        external
        whenNotPaused
        returns (uint256, uint256)
    {
        require (canWithdrawAsCake, "Cake withdrawal disabled");
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 precomputedUntilBlock
        ) = precomputeDividendsAndRewards(holderStake);
        if (
            precomputedUntilBlock != currentBlockNumber ||
            gasleft() < minimumGasForPeupleTransfer
        ) return (0, 0);
        uint256 amountToWithdraw = claimable(dividendsAndRewards) -
            holderStake.withdrawn;
        holderStake.withdrawn += amountToWithdraw;
        currentTotalOwnedPeuple -= amountToWithdraw;
        uint256 cakeToWithdraw = swapPeupleForCake(amountToWithdraw);
        transferCake(msg.sender, cakeToWithdraw);
        return (amountToWithdraw, cakeToWithdraw);
    }

    function stakeDividendsAndRewards(uint256 stakeIndex)
        external
        whenNotPaused
        returns (uint256)
    {
        HolderStake storage holderStake = holderStakes[msg.sender][stakeIndex];
        (
            DividendsAndRewards memory dividendsAndRewards,
            uint256 precomputedUntilBlock
        ) = precomputeDividendsAndRewards(holderStake);
        if (precomputedUntilBlock != currentBlockNumber || gasleft() < 80000)
            return 0;
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

    function holderStakesInfo(address holder)
        external
        view
        returns (uint256 stakesCount, uint256 totalAmount)
    {
        HolderStake[] storage stakes = holderStakes[holder];
        stakesCount = stakes.length;
        for (uint256 i = 0; i < stakesCount; ++i) {
            totalAmount += stakes[i].amount;
        }
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
            uint256 withdrawn,
            bool unstakable
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
        unstakable = blockedUntil < block.timestamp;
    }

    function decommission(string memory validationMessage) external onlyOwner {
        require(decommissioned == false, "already decommissioned");
        require(
            keccak256(bytes(validationMessage)) ==
                keccak256(bytes("YeSS, I aM SuRe !!!")),
            "wrong validation message"
        );
        decommissioned = true;
        decommissionTime = block.timestamp;
    }

    function cancelDecommission(string memory validationMessage)
        external
        onlyOwner
    {
        require(decommissioned == true, "not decommissioned");
        require(
            keccak256(bytes(validationMessage)) ==
                keccak256(bytes("YeSS, I aM SuRe !!!")),
            "wrong validation message"
        );
        decommissioned = false;
    }

    function emptyWholeWallet(address recipient) external onlyOwner {
        require(decommissioned == true, "Not decommissioned");
        require(
            decommissionTime + 120 days < block.timestamp,
            "120 days after decommission"
        );
        currentTotalStake = 0;
        currentTotalPonderedStake = 0;
        currentTotalOwnedPeuple = 0;
        currentBlockCakeRewards = 0;
        uint256 peupleAmount = IERC20(peuple).balanceOf(address(this));
        transferPeuple(recipient, peupleAmount);
        uint256 cakeAmount = IERC20(cake).balanceOf(address(this));
        transferCake(recipient, cakeAmount);

        emit StakingEnded();
    }

    function transferPeuple(address recipient, uint256 amount) internal {
        IERC20(peuple).safeTransfer(recipient, amount);
    }

    function transferCake(address recipient, uint256 amount) internal {
        IERC20(cake).safeTransfer(recipient, amount);
    }

    function transferPeupleFrom(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        uint256 allowance = IERC20(peuple).allowance(sender, recipient);
        require(allowance >= amount, "Staking: check allowance");
        IERC20(peuple).safeTransferFrom(sender, recipient, amount);
    }

    function transferCakeFrom(
        address sender,
        address recipient,
        uint256 amount
    ) internal {
        uint256 allowance = IERC20(cake).allowance(sender, recipient);
        require(allowance >= amount, "Staking: check allowance");
        IERC20(cake).safeTransferFrom(sender, recipient, amount);
    }

    function swapCakeForPeuple(uint256 amount) internal returns (uint) {
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

    function swapPeupleForCake(uint256 amount) internal returns (uint) {
        IERC20(peuple).approve(address(uniswapV2Router), amount);
    
        address[] memory path = new address[](3);
        path[0] = peuple;
        path[1] = uniswapV2Router.WETH(); // WBNB
        path[2] = cake;

        // Make the swap
        uint[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp + 5 minutes
        );
        return amounts[2];
    }
}
