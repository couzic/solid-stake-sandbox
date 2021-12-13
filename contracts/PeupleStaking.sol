// SPDX-License-Identifier: MIT
import "./HitchensUnorderedAddressSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";

pragma solidity ^0.8.0;

contract PeupleStaking is Ownable, Pausable {
    using HitchensUnorderedAddressSetLib for HitchensUnorderedAddressSetLib.Set;
    HitchensUnorderedAddressSetLib.Set private stakerSet;

    struct StakerStruct {
        uint256 staked; // actuellement staké
        uint256 earned; // actuellement gagné
        uint256 starting; // timestamp de départ
        uint256 ending; // timestamp de fin d'engagement
        uint256 bonus; // bonus (pushed)
        uint256 share; // share originale de la pool
        uint256 shareBonus; // share boosté de la pool
    }

    mapping(address => StakerStruct) public stakers;

    address public immutable peupleWallet;
    address public immutable cakeWallet;

    constructor(address _peupleWallet, address _cakeWallet) {
        peupleWallet = _peupleWallet;
        cakeWallet = _cakeWallet;
    }

    uint256 public _total; // balance totale du token dans la pool
    // = //
    uint256 public _totalStaked; // total actuellement staké
    uint256 public _totalRewardPool; // total actuellement dans la reward pool
    uint256 public _totalDev; // total pour le système

    uint256 public _totalRewardDistributed; // total distribué (pour les stats)
    uint256 public _totalRewardDistributedToday; // total distribué aujourd'hui
    uint256 public _totalDebts = 0; // dettes

    // Taxes en pourcentage
    uint256 public taxInRewardPool = 2;
    uint256 public taxInDev = 1;
    uint256 public taxOutRewardPool = 2;
    uint256 public taxOutDev = 1;

    uint256 public taxInTotal = taxInRewardPool + taxInDev;
    uint256 public taxOutTotal = taxOutRewardPool + taxOutDev;

    uint256 public taxOutEarlyRewardPool = 22;
    uint256 public taxOutEarlyDev = 3;
    uint256 public taxOutEarlyTotal = taxOutEarlyRewardPool + taxOutEarlyDev;

    // Système de file d'attente ?
    // bool processEverything = true; // Par défaut
    // uint lastStakerProcessed; // File d'attente

    // Log
    uint256 public log;

    function calculateFee(uint256 amount, uint256 tax)
        public
        pure
        returns (uint256)
    {
        require(amount > 1000, "PEUPLE: too small amount to apply %");
        tax = tax * 100;
        uint256 totax = (amount * tax) / 10000;
        return totax;
    }

    // Let's stake those PEUPLE!

    function stake(uint256 amount, uint256 time) external payable {
        // Requirements
        require(amount >= 100000, "PEUPLE: Cannot stake less than 1 token");
        uint256 allowance = IERC20(peupleWallet).allowance(
            msg.sender,
            address(this)
        );
        require(allowance >= amount, "PEUPLE: Check the allowance");

        // NEW STAKER
        if (!stakerSet.exists(msg.sender)) {
            IERC20(peupleWallet).transferFrom(
                msg.sender,
                address(this),
                amount
            );

            stakerSet.insert(msg.sender);
            StakerStruct storage s = stakers[msg.sender];

            s.staked = amount - calculateFee(amount, taxInTotal);
            s.earned = 0;
            s.starting = block.timestamp; // Maintenant
            s.ending = block.timestamp + time;
            s.bonus = 0; // Pourcentage
            s.share = 0;
            s.shareBonus = 0;

            // UPDATING THE POOL
            _total += amount;
            _totalStaked += s.staked;
            _totalRewardPool += calculateFee(amount, taxInRewardPool);
            _totalDev += calculateFee(amount, taxInDev);

            // Calculer les shares !
            //calculateShares();
        }
        // ALREADY STAKING
        else {
            IERC20(peupleWallet).transferFrom(
                msg.sender,
                address(this),
                amount
            );

            StakerStruct storage s = stakers[msg.sender];
            s.staked += amount - calculateFee(amount, taxInTotal);

            // UPDATING THE POOL
            _total += amount;
            _totalStaked += s.staked;
            _totalRewardPool += calculateFee(amount, taxInRewardPool);
            _totalDev += calculateFee(amount, taxInDev);
        }
    }

    function unstake() external payable {
        require(stakerSet.exists(msg.sender), "PEUPLE: Staker doesn't exist");

        // Initialise
        StakerStruct storage s = stakers[msg.sender];
        uint256 amount = s.staked + s.earned;

        require(amount <= _totalStaked, "PEUPLE: Not enough liquidity");

        // TIME OVER?
        if (s.ending <= block.timestamp) {
            // RESPECTED the time contract :)

            // We transfer the caller everything minus the taxOutTotal
            uint256 unstakeAmount = amount - calculateFee(amount, taxOutTotal);
            IERC20(peupleWallet).transfer(msg.sender, unstakeAmount);

            // UPDATING THE POOL -
            _total -= amount;
            _totalStaked -= amount;

            // UPDATING THE POOL +
            _total += calculateFee(amount, taxOutTotal);
            _totalRewardPool += calculateFee(amount, taxOutRewardPool);
            _totalDev += calculateFee(amount, taxOutDev);

            // We remove the staker
            stakerSet.remove(msg.sender);
        } else {
            // DIDN'T RESPECTED the time contract :(

            // We transfer the caller everything minus the taxOutEarly
            uint256 unstakeAmount = amount -
                calculateFee(amount, taxOutEarlyTotal);
            IERC20(peupleWallet).transfer(msg.sender, unstakeAmount);

            // UPDATING THE POOL -
            _total -= amount;
            _totalStaked -= amount;

            // UPDATING THE POOL +
            _total += calculateFee(amount, taxOutEarlyTotal);
            _totalRewardPool += calculateFee(amount, taxOutEarlyRewardPool);
            _totalDev += calculateFee(amount, taxOutEarlyDev);

            // We remove the staker
            stakerSet.remove(msg.sender);
        }
    }

    function fakeStake(uint256 amount) external onlyOwner {
        // POUR TEST PENDANT LE DEVELOPPEMENT
        require(amount > 0, "PEUPLE: Cannot stake 0");
        //require((amount / 100) * 100 == amount, 'PEUPLE : Amount too small');

        //uint allowance = IERC20(PEUPLE).allowance(msg.sender, address(this));
        //require(allowance >= amount, "PEUPLE: Check the allowance");

        // New staker
        if (true) {
            //IERC20(PEUPLE).transferFrom(msg.sender, address(this), amount);

            address randomAdress = address(
                uint160(uint256(keccak256(abi.encodePacked(block.timestamp))))
            );

            stakerSet.insert(randomAdress);
            StakerStruct storage s = stakers[randomAdress];

            s.staked = amount - calculateFee(amount, taxInTotal);
            s.earned = 0;
            s.starting = block.timestamp; // Maintenant
            s.ending = block.timestamp + 30; // Pour 30 secondes
            s.bonus = 0; // Pourcentage
            s.share = 0;
            s.shareBonus = 0;

            _total += amount;
            _totalStaked += s.staked;
            _totalRewardPool += calculateFee(amount, taxInRewardPool);
            _totalDev += calculateFee(amount, taxInDev);

            //calculateShares();
        }
    }

    function calculateShares() public {
        // Initialise
        _totalRewardDistributedToday = 0;
        uint256 r = 0;
        uint256 totalDistribution = 0;
        uint256 totalStaker = 0;
        uint256 startingRewardPool = _totalRewardPool;
        uint256 tempRewardPool = 0;

        // On check les dettes
        if (_totalDebts > 0 && _totalDebts <= _totalRewardPool) {
            // On a bien des dettes mais moins que la Reward Pool
            tempRewardPool = _totalRewardPool - _totalDebts;
        } else if (_totalDebts > 0 && _totalDebts > _totalRewardPool) {
            // On a des dettes mais plus que la Reward Pool
            tempRewardPool = 0;
        } else {
            // Pas de dettes
            tempRewardPool = _totalRewardPool;
        }

        // Nombre total de stakers actifs
        uint256 stakersTotal = stakerSet.count();

        // LOOP // On parcourt tous les stakers
        for (uint256 i = 0; i < stakersTotal; i++) {
            // Staker en cours d'analyse
            address a = stakerSet.keyAtIndex(i);
            StakerStruct storage s = stakers[a];

            totalDistribution = _totalStaked + tempRewardPool;
            totalStaker = s.staked + s.earned;
            s.share = 10e18 / (totalDistribution / totalStaker);

            // On ajoute le bonus
            uint256 bonus = s.bonus * 10e18;
            s.shareBonus = s.share + ((s.share * (bonus / 100)) / 10e18);

            // Calcul et ajout du gain à distribuer au staker
            r = (tempRewardPool * s.shareBonus) / 10e18;
            s.earned += r;
            // Suivi
            _totalRewardDistributedToday += r;
        }

        // Mise à jour des Dettes
        if (_totalRewardDistributedToday > tempRewardPool) {
            // On a des dettes
            _totalDebts = _totalRewardDistributedToday - tempRewardPool;
        } else if (_totalRewardDistributedToday <= tempRewardPool) {
            // On est à l'équilibre ou on a des restes
            _totalDebts = 0; // car on a forcément épongé les dettes
        }

        // Mise à jour de la Reward Pool
        if (_totalRewardDistributedToday <= _totalRewardPool) {
            _totalRewardPool -= _totalRewardDistributedToday; // On a des restes dans la Reward Pool
        } else if (_totalRewardDistributedToday > _totalRewardPool) {
            _totalRewardPool = 0; // Endetté et répercuté plus haut dans _totalDebts.
        }

        // On transvase ce qui est sorti de la Reward Pool dans la Staking Pool
        _totalStaked += startingRewardPool - _totalRewardPool;

        // Pour stats
        _totalRewardDistributed += _totalRewardDistributedToday;
    }

    // VIEWS

    // How many active stakers?
    function showStakersCount() external view returns (uint256) {
        return stakerSet.count();
    }

    // What about this staker (based on ID) ?
    function showStaker(uint256 id)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        address a = stakerSet.keyAtIndex(id);
        StakerStruct storage s = stakers[a];

        return (
            a,
            s.staked,
            s.earned,
            s.starting,
            s.ending,
            s.bonus,
            s.share / 10e16,
            s.shareBonus / 10e16
        );
    }

    function showTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function showBalance() external view returns (uint256) {
        return IERC20(peupleWallet).balanceOf(address(this));
    }

    function withdrawToken(address token) external onlyOwner {
        IERC20(token).transfer(
            msg.sender,
            IERC20(token).balanceOf(address(this))
        );
    }

    function unstakeAvailable() public view returns (uint256) {
        StakerStruct storage s = stakers[msg.sender];
        uint256 amount = s.staked + s.earned;
        uint256 unstakeAmount = calculateFee(amount, taxOutTotal);
        return unstakeAmount;
    }
}
