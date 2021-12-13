// SPDX-License-Identifier: MIT
import "./IStaking.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";

pragma solidity ^0.8.0;

contract SwapPool is Ownable {
    uint256 constant cakeRatio = 10**6;
    uint256 constant ethRatio = cakeRatio * 10;

    address internal peuple;
    address internal immutable cake;

    constructor(address _cake) {
        cake = _cake;
    }

    function setPeupleAddress(address peupleAddress) public {
        peuple = peupleAddress;
    }

    function swapPeupleForCake(uint256 peupleAmount) public {
        IERC20(peuple).transferFrom(peuple, address(this), peupleAmount);
        uint256 cakeAmount = peupleAmount / cakeRatio;
        IERC20(cake).transfer(peuple, cakeAmount);
    }

    function convertCakeIntoPeuple(address buyer, uint256 cakeAmount)
        public
        returns (uint256)
    {
        IERC20(cake).transferFrom(buyer, address(this), cakeAmount);
        uint256 peupleAmount = cakeAmount * cakeRatio;
        IERC20(peuple).transfer(buyer, peupleAmount);
        return peupleAmount;
    }

    function buyPeupleWithCake(uint256 cakeAmount) public returns (uint256) {
        IERC20(cake).transferFrom(msg.sender, address(this), cakeAmount);
        uint256 peupleAmount = cakeAmount * cakeRatio;
        IERC20(peuple).transfer(msg.sender, peupleAmount);
        return peupleAmount;
    }

    function sellPeupleForCake(uint256 peupleAmount) public {
        IERC20(peuple).transferFrom(msg.sender, address(this), peupleAmount);
        uint256 cakeAmount = peupleAmount / cakeRatio;
        IERC20(cake).transfer(peuple, cakeAmount);
    }
}
