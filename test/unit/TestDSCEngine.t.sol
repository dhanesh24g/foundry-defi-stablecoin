// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract TestDSCEngine is Test {
    // By-default all are internal variables
    DeployDSCEngine deployer;
    HelperConfig config;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;

    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    address private USER = makeAddr("user");
    address private LIQUIDATOR = address(1);
    uint256 private constant INITIAL_ERC20_BALANCE = 15 ether;
    uint256 private constant APPROVED_COLLATERAL_AMOUNT = 20 ether;
    uint256 private constant COLLATERAL_AMOUNT = 10 ether;
    uint256 private constant DEFAULT_MINTING_AMOUNT_USD = 5000 ether; // (Against 20K Collateral)
    uint256 private constant OVERALL_ETH_PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Debt worth 50% of the collateral
    uint256 private constant LIQUIDATION_BONUS_PERCENT = 10;
    uint256 private constant APPROVED_BURNING_AMOUNT_USD = 20000 ether;

    ///////////////////
    // Modifiers    //
    //////////////////

    modifier withApprovedCollateral() {
        vm.startPrank(USER);
        // Approve wBTC & wETH with initial collateral value
        ERC20Mock(weth).approve(address(dscEngine), APPROVED_COLLATERAL_AMOUNT);
        ERC20Mock(wbtc).approve(address(dscEngine), APPROVED_COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier withDepositedCollateral() {
        vm.startPrank(USER);
        // Approve wBTC & wETH with initial collateral value
        ERC20Mock(weth).approve(address(dscEngine), APPROVED_COLLATERAL_AMOUNT);
        ERC20Mock(wbtc).approve(address(dscEngine), APPROVED_COLLATERAL_AMOUNT);
        dscEngine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier withDepositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), APPROVED_COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, DEFAULT_MINTING_AMOUNT_USD);
        vm.stopPrank();
        _;
    }

    modifier withLiquidationSetup() {
        vm.startBroadcast();
        ERC20Mock(weth).mint(LIQUIDATOR, 100 * INITIAL_ERC20_BALANCE);
        vm.stopBroadcast();
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), 10 * APPROVED_COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, 20 * COLLATERAL_AMOUNT, 2 * DEFAULT_MINTING_AMOUNT_USD);
        vm.stopPrank();

        // ETH price falls to 800 USD
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(800e8);
        _;
    }

    //////////////////////////////
    // setUp & Test Functions  //
    /////////////////////////////

    function setUp() external {
        deployer = new DeployDSCEngine();
        (dsc, dscEngine, config) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        // Mint the tokens for USER
        vm.startBroadcast();
        ERC20Mock(weth).mint(USER, INITIAL_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, INITIAL_ERC20_BALANCE);
        vm.stopBroadcast();
    }

    /////////////////////////
    // Constructor Tests  //
    ////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertInConstructor() public {
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed, btcUsdPriceFeed];

        // Length of tokenAddresses & priceFeedAddresses won't match
        vm.expectRevert(DSCEngine.DSCEngine__NumberOfTokenAndPriceFeedAddressesMustBeSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////////
    // Price Feed Tests  //
    ///////////////////////

    function testGetTokenAmountFromUsd() public view {
        // wETH value = $2000 || Test the value for $500
        uint256 amountInWei = 500 ether;
        uint256 expectedWeth = 0.25 ether;

        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, amountInWei);
        // console.log("Expected- ", expectedWeth, " Actual- ", actualWeth);
        assert(expectedWeth == actualWeth);
    }

    function testGetUsdValue() public view {
        uint256 numberOfEth = 15e18;
        // expectedValue = 15e18 * 2000USD = 30,000e18
        uint256 expectedEthValue = 30000e18;
        uint256 numberOfBtc = 10e18;
        // expectedValue = 10e18 * 4000USD = 40,000e18
        uint256 expectedBtcValue = 40000e18;
        uint256 actualEthValue = dscEngine.getUsdValue(weth, numberOfEth);
        uint256 actualBtcValue = dscEngine.getUsdValue(wbtc, numberOfBtc);

        // Testing for ETH
        assert(expectedEthValue == actualEthValue);
        // Testing for BTC
        assert(expectedBtcValue == actualBtcValue);
    }

    ////////////////////////
    // Collateral Tests  //
    ///////////////////////

    function testGetTotalCollateralInUSD() public withDepositedCollateral {
        // Add more wBTC collateral along with initial wETH collateral
        vm.startPrank(USER);
        dscEngine.depositCollateral(wbtc, 5 ether);
        // 10 ether (wETH) + 5 ether (wBTC) = (10 * $2000) + (5 * $4000) = $40000
        uint256 expectedUsdValue = 40000e18;
        uint256 actualUsdValue = dscEngine.getTotalCollateralInUSD(USER);
        vm.stopPrank();
        // console.log("actualValue - ", actualUsdValue);
        assert(expectedUsdValue == actualUsdValue);
    }

    function testDepositCollateralAndGetAccountInfo() public withDepositedCollateral {
        (uint256 actualDscMinted, uint256 actualCollateralInUSD) = dscEngine.getAccountInformation(USER);
        // Convert the expected answer to USD
        uint256 expectedCollateralInUSD = dscEngine.getUsdValue(weth, COLLATERAL_AMOUNT);
        assert(expectedCollateralInUSD == actualCollateralInUSD);
        // DSC has not been minted yet
        assert(actualDscMinted == 0);
    }

    function testWithUnapprovedCollateral() public {
        // Creating new token apart from the approved ones
        ERC20Mock newToken = new ERC20Mock();

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        // Sending newly created token with the allowed collateral & expecting to revert
        dscEngine.depositCollateral(address(newToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        // Try with a mock user
        vm.startPrank(USER);

        // Approve the token & its depositing allowance for DSCEngine as owner
        ERC20Mock(weth).approve(address(dscEngine), APPROVED_COLLATERAL_AMOUNT);

        // Log the value for confirmation -> Getting wETH balance will need special handling
        console.log("Approved allowance - ", APPROVED_COLLATERAL_AMOUNT);
        console.log("User wETH balance - ", ERC20Mock(weth).balanceOf(USER));

        // Expecting to revert by sending ZERO collateral deposit
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }

    function testRevertsIfDepositMoreThanAllowance() public {
        vm.startPrank(USER);

        // Approve the token & its depositing allowance for DSCEngine as owner
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);

        // Depositing wETH within the approved allownace
        dscEngine.depositCollateral(weth, 8 * OVERALL_ETH_PRECISION);

        // Expecting to revert by sending over the approved allowance
        vm.expectRevert();
        dscEngine.depositCollateral(weth, 4 * OVERALL_ETH_PRECISION);
        vm.stopPrank();
    }

    /////////////////////
    // Minting Tests  //
    ////////////////////

    function testRevertsOnMintingWithBrokenHealthFactor() public withDepositedCollateral {
        // Total collateral => 10 * $2000 || MaxMinting => 10000e18
        // Try to mint extra DSC by breaking healthFactor
        uint256 dscToMintInUsd = 15000e18;
        // 66% debt taken, instead of 50%
        uint256 expectedHealthFactor = 666666666666666666;

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBelowMinimum.selector, expectedHealthFactor)
        );
        dscEngine.mintDsc(dscToMintInUsd);
        vm.stopPrank();
    }

    function testMintingWithZeroDsc() public withDepositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsOnDepositCollateralAndMintZeroDsc() public withApprovedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, 0);
        vm.stopPrank();
    }

    /////////////////////////
    // HealthFactor Tests //
    ////////////////////////

    function testMintDscAndCheckHealthFactor() public withDepositedCollateral {
        vm.startPrank(USER);
        // Passing full allowed amount to be minted
        dscEngine.mintDsc(2 * DEFAULT_MINTING_AMOUNT_USD);
        assert(MIN_HEALTH_FACTOR == dscEngine.getCurrentHealthFactor(USER));
    }

    function testCurrentHealthFactor() public withDepositedCollateral {
        console.log("Total deposited collateral - ", dscEngine.getTotalCollateralInUSD(USER));
        uint256 amountToMint = dscEngine.getMaxMintingLimitInUSD(USER);
        uint256 expectedHealthFactor = MIN_HEALTH_FACTOR;
        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);
        uint256 actualHealthFactor = dscEngine.getCurrentHealthFactor(USER);
        vm.stopPrank();
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testDepositCollateralAndMintDsc() public withApprovedCollateral {
        vm.startPrank(USER);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, DEFAULT_MINTING_AMOUNT_USD);
        vm.stopPrank();
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        console.log("Minted DSC - ", totalDscMinted);
        assert(totalDscMinted == DEFAULT_MINTING_AMOUNT_USD);
        assert(dscEngine.getCurrentHealthFactor(USER) > MIN_HEALTH_FACTOR);
    }

    function testRevertsDepositCollateralAndMintDscOnBrokenHealthFactor() public withApprovedCollateral {
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, 30000 ether);
        vm.stopPrank();
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        assert(totalDscMinted == 0);
    }

    //////////////////////////
    // Redeem & Burn Tests //
    /////////////////////////

    function testRevertsOnRedeemingZeroCollateral() public withDepositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsOnRedeemingFullCollateral() public withDepositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        // Redeeming full collateral will reduce the healthFactor to ZERO
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorIsBelowMinimum.selector, 0));
        dscEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testRedeemCollateral() public withDepositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        (, uint256 totalCollateralBeforeRedemption) = dscEngine.getAccountInformation(USER);
        console.log("totalCollateralBeforeRedemption - ", totalCollateralBeforeRedemption);

        // Amount to be redeemed should be passed in ETH
        dscEngine.redeemCollateral(weth, 5 ether);
        uint256 healthFactor = dscEngine.getCurrentHealthFactor(USER);
        (, uint256 totalCollateralAfterRedemption) = dscEngine.getAccountInformation(USER);
        vm.stopPrank();

        // HealthFactor after redemption should be exactly equal to 1e18
        // totalCollateral should decrease as compared to the original one
        console.log("HealthFactor - ", healthFactor);
        console.log("TotalCollateralAfterRedemption - ", totalCollateralAfterRedemption);
        assert(healthFactor == MIN_HEALTH_FACTOR);
        assert(totalCollateralAfterRedemption < totalCollateralBeforeRedemption);
    }

    function testRevertsOnBurningZeroDsc() public withDepositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCannotBurnMoreThanUserDscBalance() public withDepositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), APPROVED_BURNING_AMOUNT_USD);
        // Will burn all the DSC Owned
        dscEngine.burnDsc(5000 ether);

        // Expect to revert if try to burn more than the balance
        vm.expectRevert(DSCEngine.DSCEngine__CannotBurnMoreThanYouOwn.selector);
        dscEngine.burnDsc(1 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralForDsc() public withDepositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), APPROVED_BURNING_AMOUNT_USD);
        // Total deposited collateral is 20K USD & minted is 5000 USD
        dscEngine.redeemCollateralForDsc(weth, 6e18, 1000e18);

        // Redeemed 6 ETH (12K USD) & burnt 1000 USD || DSC - 4K USD & Collateral - 8K USD
        uint256 currentHealthFactor = dscEngine.getCurrentHealthFactor(USER);
        vm.stopPrank();
        assert(currentHealthFactor == MIN_HEALTH_FACTOR);
    }

    ////////////////////////
    // Liquidation Tests //
    ///////////////////////

    function testCannotLiquidateWithGoodHealthFactor() public withDepositedCollateralAndMintedDsc {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorAboveLiquidationThreshold.selector);
        dscEngine.liquidate(weth, USER, 500e18);
        vm.stopPrank();
    }

    function testLiquidatedSuccessfully() public withDepositedCollateralAndMintedDsc withLiquidationSetup {
        (uint256 totalDscMintedBefore, uint256 totalCollateralBefore) = dscEngine.getAccountInformation(USER);
        uint256 beforeHealthFactorUser = dscEngine.getCurrentHealthFactor(USER);
        // console.log("HealthFactor Before - ", beforeHealthFactorUser);
        // console.log("TotalDscMinted & TotalCollateral - ", totalDscMinted, totalCollateral);
        (uint256 totalDscMintedLiq, uint256 totalCollateralLiq) = dscEngine.getAccountInformation(LIQUIDATOR);
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), totalDscMintedBefore);
        dscEngine.liquidate(weth, USER, totalDscMintedBefore);
        vm.stopPrank();
        uint256 afterHealthFactorUser = dscEngine.getCurrentHealthFactor(USER);
        (totalDscMintedLiq, totalCollateralLiq) = dscEngine.getAccountInformation(LIQUIDATOR);
        (uint256 totalDscMintedAfter, uint256 totalCollateralAfter) = dscEngine.getAccountInformation(USER);
        assert(afterHealthFactorUser > beforeHealthFactorUser);
        assert(totalDscMintedAfter == 0);
        assert(totalCollateralBefore > totalCollateralAfter);
    }

    function testDoesNotBreakLiquidatorHealthFactor() public withDepositedCollateralAndMintedDsc withLiquidationSetup {
        (uint256 totalDscMintedBefore,) = dscEngine.getAccountInformation(USER);
        uint256 liquidatorHealthFactorBefore = dscEngine.getCurrentHealthFactor(LIQUIDATOR);
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), totalDscMintedBefore);
        dscEngine.liquidate(weth, USER, totalDscMintedBefore);
        vm.stopPrank();
        (uint256 totalDscMintedAfter,) = dscEngine.getAccountInformation(USER);
        uint256 liquidatorHealthFactorAfter = dscEngine.getCurrentHealthFactor(LIQUIDATOR);
        assert(totalDscMintedAfter < totalDscMintedBefore);
        assert(liquidatorHealthFactorAfter > liquidatorHealthFactorBefore);
    }

    function testLiquidatorEarnsBonus() public withDepositedCollateralAndMintedDsc withLiquidationSetup {
        (uint256 userTotalDscMintedBefore, uint256 userTotalCollateralBefore) = dscEngine.getAccountInformation(USER);
        (, uint256 liquidatorTotalCollateralBefore) = dscEngine.getAccountInformation(LIQUIDATOR);
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), userTotalDscMintedBefore);
        dscEngine.liquidate(weth, USER, userTotalDscMintedBefore);
        vm.stopPrank();
        (, uint256 userTotalCollateralAfter) = dscEngine.getAccountInformation(USER);
        (, uint256 liquidatorTotalCollateralAfter) = dscEngine.getAccountInformation(LIQUIDATOR);
        // console.log("liquidatorTotalCollateralAfter - ", liquidatorTotalCollateralAfter);
        assert(
            liquidatorTotalCollateralAfter + userTotalCollateralAfter
                == userTotalCollateralBefore + liquidatorTotalCollateralBefore
        );
        uint256 bonus = dscEngine.getLiquidationBonus(userTotalDscMintedBefore);

        // Liquidator should receive ETH worth the DSC burnt + the 10% bonus of it
        assert(liquidatorTotalCollateralAfter == liquidatorTotalCollateralBefore + userTotalDscMintedBefore + bonus);
    }

    function testUserStillHoldsSomeEth() public withDepositedCollateralAndMintedDsc withLiquidationSetup {
        (uint256 userTotalDscMintedBefore, uint256 userTotalCollateralBefore) = dscEngine.getAccountInformation(USER);
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dscEngine), userTotalDscMintedBefore);
        dscEngine.liquidate(weth, USER, userTotalDscMintedBefore);
        vm.stopPrank();

        (, uint256 userTotalCollateralAfter) = dscEngine.getAccountInformation(USER);
        uint256 bonus = dscEngine.getLiquidationBonus(userTotalDscMintedBefore);
        uint256 expectedUserBalance = userTotalCollateralBefore - userTotalDscMintedBefore - bonus;
        // User should hold balance worth after removing the mintedDSC & its equivalent bonus
        assert(userTotalCollateralAfter == expectedUserBalance);
    }

    ////////////////////////
    // Getter Func Tests //
    ///////////////////////

    function testGetMinimumHealthFactor() public view {
        assert(dscEngine.getMinHealthFactor() == MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        assert(dscEngine.getLiquidationThreshold() == LIQUIDATION_THRESHOLD);
    }

    function testGetLiquidationBonusPercentage() public view {
        assert(dscEngine.getLiquidationBonusPercentage() == LIQUIDATION_BONUS_PERCENT);
    }
}
