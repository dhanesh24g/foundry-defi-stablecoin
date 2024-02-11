// SPDX-License-Identifier: MIT

// Handler will narrow down the function calls

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;

    ERC20Mock weth;
    ERC20Mock wbtc;

    address[] usersWithCollateral;

    // Max uint96 value is safer than max uint256 value, as any addition will revert max of uint256
    uint256 MAX_DEPOSIT_AMOUNT = type(uint96).max;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _dscEngine) {
        dsc = _dsc;
        dscEngine = _dscEngine;

        address[] memory tokenAddresses = dscEngine.getCollateralTokens();
        weth = ERC20Mock(tokenAddresses[0]);
        wbtc = ERC20Mock(tokenAddresses[1]);
    }

    /**
     * @param collateralSeed: Random input to choose from the approved token addresses
     * The input can be handled using MOD function to choose from the 2 tokens
     */
    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateralToken = _getCollateralTokenFromSeed(collateralSeed);
        uint256 validCollateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_AMOUNT);

        console.log("ValidCollateralAmount -", validCollateralAmount);
        console.log("CollateralToken -", address(collateralToken));

        vm.startPrank(msg.sender);
        collateralToken.mint(msg.sender, validCollateralAmount);
        collateralToken.approve(address(dscEngine), validCollateralAmount);
        dscEngine.depositCollateral(address(collateralToken), validCollateralAmount);
        vm.stopPrank();

        usersWithCollateral.push(msg.sender);
    }

    /**
     *
     * @notice Below function will change the priceFeed value randomly.
     * The value can go from $2000 to $20 and this will break our contract longtime.
     * This is a bug & we should find a better solution for such situation. (Will come in AUDIT)
     */
    // function updateCollatralPrice(uint96 newPrice) {}

    function redeemCollateral(uint256 collateralSeed, uint256 redeemAmount) public {
        ERC20Mock collateralToken = _getCollateralTokenFromSeed(collateralSeed);
        address user = msg.sender;
        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(address(collateralToken), user) / 5;

        console.log("CollateralToken while redeeming -", address(collateralToken));

        if (maxCollateralToRedeem == 0 && usersWithCollateral.length > 0) {
            user = usersWithCollateral[collateralSeed % usersWithCollateral.length];
            console.log("Choosing another address -", user);
            maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(address(collateralToken), user) / 5;
        }

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(user);

        int256 totalAmountToRedeem = int256(maxCollateralToRedeem / 2) - int256(totalDscMinted);

        console.log("maxCollateralToRedeem -", maxCollateralToRedeem);
        console.log("totalAmountToRedeem -", uint256(totalAmountToRedeem));

        if (totalAmountToRedeem <= 0) {
            console.log("Amount cannot be redeemed !");
            return;
        }

        redeemAmount = bound(redeemAmount, 0, uint256(totalAmountToRedeem));

        console.log("FinalRedeemAmount -", redeemAmount);

        if (redeemAmount == 0) return;

        vm.startPrank(user);
        dscEngine.redeemCollateral(address(collateralToken), redeemAmount);
        vm.stopPrank();
        console.log("Collateral Redeemed!");
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        // console.log("Minting DSC amount -", amount);

        if (usersWithCollateral.length == 0) return;

        address user = usersWithCollateral[addressSeed % usersWithCollateral.length];
        console.log("User address -", user);

        (uint256 totalDscMinted, uint256 totalCollateral) = dscEngine.getAccountInformation(user);

        int256 maxDscToMint = int256(totalCollateral / 2) - int256(totalDscMinted);

        if (maxDscToMint < 0) return;

        amount = bound(amount, 0, uint256(maxDscToMint));

        if (amount == 0) return;

        vm.startPrank(user);
        dscEngine.mintDsc(amount);
        vm.stopPrank();
        console.log("DSC amount Minted-", amount);
    }

    function _getCollateralTokenFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }

        return wbtc;
    }
}
