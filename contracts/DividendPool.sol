// SPDX-License-Identifier: MIT
import "./CAKE.sol";
import "./HitchensUnorderedAddressSet.sol";
import "./LePeuple.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";

pragma solidity ^0.8.0;

contract DividendPool is Ownable {
    CAKE private immutable cake;

    constructor(CAKE _cake) {
        cake = _cake;
    }
}
