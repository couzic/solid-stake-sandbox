// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (access/Ownable.sol)
// Updated by LE PEUPLE / New role: pusher.

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;
    address private _pusher;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PushershipTransferred(address indexed previousPusher, address indexed newPusher);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner and pusher.
     */
    constructor() {
        _transferOwnership(_msgSender());
        _transferPushership(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Returns the address of the current pusher.
     */
    function pusher() public view virtual returns (address) {
        return _pusher;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyPusher() {
        require(pusher() == _msgSender(), "Ownable: caller is not the pusher");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers pushership of the contract to a new account (`newPusher`).
     * Can only be called by the current owner.
     */
    function transferPushership(address newPusher) public virtual onlyOwner {
        require(newPusher != address(0), "Ownable: new pusher is the zero address");
        _transferPushership(newPusher);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @dev Transfers pushership of the contract to a new account (`newPusher`).
     * Internal function without access restriction.
     */
    function _transferPushership(address newPusher) internal virtual {
        address oldPusher = _pusher;
        _pusher = newPusher;
        emit PushershipTransferred(oldPusher, newPusher);
    }
}
