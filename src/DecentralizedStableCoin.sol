// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Dhanesh Gujrathi
 * Collateral: Exogenous (wETH & wBTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * This contract is meant to be governed by the DSCEngine.
 * This contract is just the ERC20 implementation of our stablecoin system.
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__CannotBeZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSCD") Ownable(msg.sender) {}

    function burn(uint256 _amountToBurn) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amountToBurn <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }

        if (balance < _amountToBurn) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        // super keyword is used to call the function of the parent class (with Same name)
        super.burn(_amountToBurn);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__CannotBeZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }

        // Call the actual mint function
        _mint(_to, _amount);
        return true;
    }
}
