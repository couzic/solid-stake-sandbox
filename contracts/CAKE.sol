// SPDX-License-Identifier: MIT
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

pragma solidity ^0.8.0;

contract CAKE is ERC20, Ownable {
    constructor() ERC20("Cake", "CAKE") {
        _mint(owner(), 100000000 * (10**18));
    }
}
