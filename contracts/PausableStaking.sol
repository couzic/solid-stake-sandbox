// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (security/Pausable.sol)
// Updated by LE PEUPLE / Allow new actions after x time of pause.

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";
import "./OwnableStaking.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context, Ownable {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;
    uint public _pausedTime; // 0 if not paused
    uint public _pausedTimeBeforeAction;
 
    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor() {
        _paused = false;
        _pausedTime = 0;
        _pausedTimeBeforeAction = 90 days;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    function pausedLongEnough() public view virtual returns (bool) {
        if(_paused && (block.timestamp > (_pausedTime + _pausedTimeBeforeAction))) {
            return _paused;
        } else {
            return false;
        }
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!paused(), "Staking: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(paused(), "Staking: not paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused long enough
     *
     * Requirements:
     *
     * - The contract must be paused.
     * - For at least the value of _pausedTimeBeforeAction (3 months by default)
     */
    modifier whenPausedLongEnough() {
        require(pausedLongEnough(), "Staking: not paused long enough");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() public onlyOwner whenNotPaused {
        _paused = true;
        _pausedTime = block.timestamp;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() public onlyOwner whenPaused {
        _paused = false;
        _pausedTime = 0;
        emit Unpaused(_msgSender());
    }
}
