// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Dhanesh Gujrathi
 *
 * The system is designed to be as minimal as possible & have the tokens maintain a 1 token == 1 USD peg.
 * This stableCoin has following properties -
 * - Exogenous collateral (The failure of StableCoin doesn't impact underlying collateral)
 * - Dollar pegged
 * - Algorithmically stable
 *
 * This contract is similar to DAI, but has following differences -
 * - Has no governance
 * - No fees
 * - Only backed by wETH & wBTC
 *
 * Our DSC system must always be "OverCollateralized".
 * At no point, should the value of all the $ backed DSCs be more than than all the collateral.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic
 * for mining & redeeming DSC, as well depositing & withdrawing the collateral.
 * @notice This contract is loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors       //
    //////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__NumberOfTokenAndPriceFeedAddressesMustBeSame();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorIsBelowMinimum(uint256);
    error DSCEngine__MintingFailed();
    error DSCEngine__HealthFactorAboveLiquidationThreshold();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__CannotBurnMoreThanYouOwn();

    /////////////////
    // Type       //
    ////////////////

    using OracleLib for AggregatorV3Interface;

    ///////////////////////////////////
    // State & Immutable Variables  //
    //////////////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant OVERALL_PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Debt worth 50% of the collateral
    uint256 private constant PERCENTAGE_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS_PERCENT = 10;

    mapping(address token => address priceFeed) private s_priceFeed;
    mapping(address user => mapping(address token => uint256 collateralAmount)) private s_userDepositedCollateral;
    mapping(address user => uint256 mintedAmount) private s_DSCMinted;
    address[] private s_collateralTokenAddresses;

    DecentralizedStableCoin private i_dsc;

    ///////////////////
    // Events       //
    //////////////////

    event collateralDeposited(address indexed user, address indexed token, uint256 amount);
    event collateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    ///////////////////
    // Modifiers    //
    //////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedCollateralToken(address tokenAddress) {
        if (s_priceFeed[tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ///////////////////
    // Constructor  //
    //////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__NumberOfTokenAndPriceFeedAddressesMustBeSame();
        }

        // Map Token addresses to PriceFeed address (ETH/USD or BTC/USD)
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokenAddresses.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    // External Functions    //
    ///////////////////////////

    /**
     * @param collateralToken:  The address of the token provided as collateral (wETH or wBTC)
     * @param collateralAmount: The amount of collateral to deposit
     * @param amountOfDscToMint: Amount of stablecoins to mint
     * @notice This function will deposit the collateral & mint DSC in single transaction
     */
    function depositCollateralAndMintDsc(address collateralToken, uint256 collateralAmount, uint256 amountOfDscToMint)
        external
    {
        depositCollateral(collateralToken, collateralAmount);
        mintDsc(amountOfDscToMint);
    }

    /**
     * @param amountToRedeem: Amount of collateral to redeem
     * @param dscToBurn: Amount of DSC to burn to free-up the collateral
     * @notice This function first burns the DSC & then redeem the collateral while also checking the health factor
     */
    function redeemCollateralForDsc(address collateralToken, uint256 amountToRedeem, uint256 dscToBurn) external {
        burnDsc(dscToBurn);
        redeemCollateral(collateralToken, amountToRedeem);
        // redeemCollateral already checks health factor
    }

    /**
     * @notice msg.sender is the Liquidator for this function
     *
     * @param user: User who has broken the healthFactor (Below the MIN_HEALTH_FACTOR value)
     * @param collateralToken: The ERC20 token address to liquidate from the user (wETH / wBTC)
     * @param debtToCover: (In USD) Amount of DSC the liquidator needs to burn (From his pocket) to improve the user's HealthFactor
     *
     * @notice One can partially liquidate a user (with a small debtToCover)
     * @notice The function would provide 10% liquidation bonus with an assumption that the protocol would be 200% collatarelized
     * @notice A possible bug - Liquidation bonus would not be paid if the protocol is 100% or less collateralized
     * Eg. If the price of the collateral collapses below 100%, before anyone could liquidate
     *
     * @notice Follows CEI - Checks, Effects, Interactions
     */
    function liquidate(address collateralToken, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Check the user's current healthFactor
        uint256 startingHealthFactor = _getCurrentHealthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorAboveLiquidationThreshold();
        }

        // Burn the user's DSC debt & take their collateral
        // Curent Collateral - $1400 wETH => $1000 DSC Debt
        // Total debt to cover - $1000 (Worth of DSC)
        // $1000 is how much wETH in WEI ? => 0.5 ETH => 0.5e18 => 5e17
        uint256 ethValueFromCoveredDebtInWei = getTokenAmountFromUsd(collateralToken, debtToCover);

        // Provide 10% Liquidation bonus to the liquidator
        uint256 liquidationBonus = getLiquidationBonus(ethValueFromCoveredDebtInWei);
        uint256 totalCollateralToLiquidator = ethValueFromCoveredDebtInWei + liquidationBonus;

        // console.log("Sender balance before - ", IERC20(collateralToken).balanceOf(msg.sender));
        // console.log("totalCollateralToLiquidator - ", totalCollateralToLiquidator);

        // Redeem the collateral from User's account & reward the Liquidator
        _redeemCollateral(user, msg.sender, collateralToken, totalCollateralToLiquidator);

        // Burn the DSC worth the debt (Would ideally be equal to the Complete DSC owned by the user)
        // msg.sender (liquidator) would burn their own DSC on behalf of the user
        _burnDsc(msg.sender, user, debtToCover);

        // Check if the healthFactor has improved or Revert the function
        uint256 endingHealthFactor = _getCurrentHealthFactor(user);
        if (endingHealthFactor < startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // Function must make sure that liquidation doesn't hamper the liquidator's healthFactor
        _revertOnBrokenHealthFactor(msg.sender);
    }

    // function getHealthFactor() external view returns (uint256) {}

    ////////////////////////////
    // Public Functions      //
    ///////////////////////////

    /**
     * @param collateralToken: The address of the token provided as collateral (wETH or wBTC)
     * @param collateralAmount: The amount of collateral to deposit
     * @notice Following CEI (Checks- Modifiers, Effect, Interactions)
     */
    function depositCollateral(address collateralToken, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedCollateralToken(collateralToken)
        nonReentrant
    {
        s_userDepositedCollateral[msg.sender][collateralToken] += collateralAmount;

        bool isSuccess = IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        if (!isSuccess) {
            revert DSCEngine__TransferFailed();
        }

        // Emitting the event as the collateral is successfully deposited
        emit collateralDeposited(msg.sender, collateralToken, collateralAmount);
    }

    /**
     * @param amountOfDscToMint: Amount of stablecoins to mint
     * @notice Caller must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountOfDscToMint) public moreThanZero(amountOfDscToMint) {
        s_DSCMinted[msg.sender] += amountOfDscToMint;

        // Revert if the healthFactor is broken
        _revertOnBrokenHealthFactor(msg.sender);

        bool isMinted = i_dsc.mint(msg.sender, amountOfDscToMint);
        if (!isMinted) {
            revert DSCEngine__MintingFailed();
        }
    }

    /**
     * @param collateralToken: The address of the token provided as collateral (wETH or wBTC)
     * @param amountToRedeem: The amount to be redemeed
     * @notice This function makes sure that the healthFactor does not fall below 1, after redemption
     */
    function redeemCollateral(address collateralToken, uint256 amountToRedeem)
        public
        moreThanZero(amountToRedeem)
        nonReentrant
        isAllowedCollateralToken(collateralToken)
    {
        _redeemCollateral(msg.sender, msg.sender, collateralToken, amountToRedeem);
        // Revert if the healthFactor is broken
        // Need to make sure the collateral is Non-Zero
        _revertOnBrokenHealthFactor(msg.sender);
    }

    function burnDsc(uint256 dscAmount) public moreThanZero(dscAmount) {
        _burnDsc(msg.sender, msg.sender, dscAmount);
    }

    /////////////////////////////////////////
    // Private & Internal View Functions  //
    ////////////////////////////////////////

    /**
     * @dev The function call must be made with caution & the healthFactor must be considered before calling
     */
    function _burnDsc(address burnFrom, address burnOnBehalfOf, uint256 dscAmountToBurn) private {
        if (s_DSCMinted[burnOnBehalfOf] < dscAmountToBurn) {
            revert DSCEngine__CannotBurnMoreThanYouOwn();
        }

        // Reduce the debt of the defaulter user
        s_DSCMinted[burnOnBehalfOf] -= dscAmountToBurn;

        // First transfer the DSC tokens to our DSC contract address & then burn
        bool isSuccess = i_dsc.transferFrom(burnFrom, address(this), dscAmountToBurn);
        if (!isSuccess) {
            revert DSCEngine__TransferFailed();
        }

        // Burn the DSC from the burnFrom's holdings, which got transferred to DSCEngine
        if (burnFrom != burnOnBehalfOf) {
            s_DSCMinted[burnFrom] -= dscAmountToBurn;
        }

        // Call the actual Burn function for to complete the ERC20 burning process
        i_dsc.burn(dscAmountToBurn);
    }

    /**
     * @dev The function call must be made with caution & the healthFactor must be checked by the calling function
     */
    function _redeemCollateral(address redeemFrom, address redeemTo, address collateralToken, uint256 amountToRedeem)
        private
    {
        s_userDepositedCollateral[redeemFrom][collateralToken] -= amountToRedeem;

        // console.log("DSCEngine balance before - ", IERC20(collateralToken).balanceOf(address(this)));
        // console.log("Sender balance before - ", IERC20(collateralToken).balanceOf(msg.sender));
        // console.log("redeemTo's balance before transfer - ", s_userDepositedCollateral[redeemTo][collateralToken]);

        // If the healthFactor stays above 1, will actually redeem the collateral
        bool isSuccess = IERC20(collateralToken).transfer(redeemTo, amountToRedeem);
        if (!isSuccess) {
            revert DSCEngine__TransferFailed();
        }

        // Update the s_userDepositedCollateral mapping after transfer
        if (redeemFrom != redeemTo) {
            s_userDepositedCollateral[redeemTo][collateralToken] += amountToRedeem;
        }

        // console.log("redeemTo's balance after transfer - ", s_userDepositedCollateral[redeemTo][collateralToken]);
        // console.log("DSCEngine balance after - ", IERC20(collateralToken).balanceOf(address(this)));
        // console.log("Sender balance after - ", IERC20(collateralToken).balanceOf(msg.sender));

        emit collateralRedeemed(redeemFrom, redeemTo, collateralToken, amountToRedeem);
    }

    function _getAccountInformation(address user) private view returns (uint256, uint256) {
        uint256 totalDscMinted = s_DSCMinted[user];
        uint256 totalCollateral = getTotalCollateralInUSD(user);

        return (totalDscMinted, totalCollateral);
    }

    /**
     * - Returns the current HealthFactor on the basis of collateral & the minted DSC.
     * - User can get liquidated if the below HealthFactor goes below 1.
     */
    function _getCurrentHealthFactor(address user) private view returns (uint256) {
        // We need total DSC minted & total collateral value
        (uint256 totalDscMinted, uint256 totalCollateral) = _getAccountInformation(user);

        // If there's no DSC minted, Divide by ZERO calculation at the end must be avoided & the max of uint256 be returned
        if (totalDscMinted == 0) return type(uint256).max;

        // 1000 ETH * 50 = 50000 / 100 = 500 ETH (If debt goes above 50%, then the loan will be liquidated)
        uint256 adjustedThresholdCollateral = (totalCollateral * LIQUIDATION_THRESHOLD) / PERCENTAGE_PRECISION;

        // Pertaining to above values, user can mint max upto 750 ETH
        return (adjustedThresholdCollateral * OVERALL_PRECISION) / totalDscMinted;
    }

    function _revertOnBrokenHealthFactor(address user) internal view {
        // 1. Check the healthFactor (Have enough collateral ?)
        // 2. Revert if collateral is not enough
        uint256 userHealthFactor = _getCurrentHealthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsBelowMinimum(userHealthFactor);
        }
    }

    ////////////////////////////////////////
    // Public & External view Functions  //
    ///////////////////////////////////////

    function getMaxMintingLimitInUSD(address user) public view returns (uint256) {
        return (getTotalCollateralInUSD(user) * LIQUIDATION_THRESHOLD / PERCENTAGE_PRECISION);
    }

    function getLiquidationBonus(uint256 _ethValueFromCoveredDebtInWei) public pure returns (uint256) {
        return (_ethValueFromCoveredDebtInWei * LIQUIDATION_BONUS_PERCENT / PERCENTAGE_PRECISION);
    }

    function getTotalCollateralInUSD(address user) public view returns (uint256 collateralValueInUSD) {
        // Loop through each collateral token, get the amount & map it to price to get the total USD value
        for (uint256 i = 0; i < s_collateralTokenAddresses.length; i++) {
            address currentToken = s_collateralTokenAddresses[i];
            uint256 amount = s_userDepositedCollateral[user][s_collateralTokenAddresses[i]];
            collateralValueInUSD += getUsdValue(currentToken, amount);
        }
        return collateralValueInUSD;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 priceInUsd,,,) = priceFeed.stalePriceCheckWithLatestRoundData();

        // Above value will have 8 decimals & our amount will have 18 decimals
        return (amount * uint256(priceInUsd) * ADDITIONAL_FEED_PRECISION) / OVERALL_PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 debtAmountInWei) public view returns (uint256) {
        // Eg. debtAmount - $1000
        // ETH price is $2000, then $1000 is how many ETH ?  ==> 0.5 ETH
        AggregatorV3Interface tokenPriceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 tokenPriceInUsd,,,) = tokenPriceFeed.stalePriceCheckWithLatestRoundData();

        // Will return $1000 / $2000 (Need to adjust for 8 decimals) => (1000e18 * 1e18) / ($2000e8 * 1e10)
        // Dealing in WEI, removes the chances of decimal values
        return (debtAmountInWei * OVERALL_PRECISION / (uint256(tokenPriceInUsd) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateral)
    {
        return _getAccountInformation(user);
    }

    function getCurrentHealthFactor(address user) external view returns (uint256) {
        return _getCurrentHealthFactor(user);
    }

    function getCollateralBalanceOfUser(address token, address user) external view returns (uint256) {
        return s_userDepositedCollateral[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokenAddresses;
    }

    function getLiquidationBonusPercentage() external pure returns (uint256) {
        return LIQUIDATION_BONUS_PERCENT;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }
}
