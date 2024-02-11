// SPDX-License-Identifier: MIT

// // List-down our invariants (Properties that should always hold true)
// // 1. Getter view functions should never revert (An Evergreen invariant)
// // 2. Total DSC Supply must be less than the total value of collateral

pragma solidity ^0.8.18;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {
//     // By-default all are internal variables
//     DeployDSCEngine deployer;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() external {
//         deployer = new DeployDSCEngine();
//         (dsc, dscEngine, config) = deployer.run();

//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dscEngine));
//     }

//     function invariant_protocolMustHaveMoreCollateralThanSupply() public view {
//         // Get the total DSC minted as debt
//         // Calling the totalSupply function from the ERC20 contract
//         uint256 totalSupply = dsc.totalSupply();

//         // Get the value of all the collateral deposited in the protocol
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         uint256 wethValueInUsd = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValueInUsd = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

//         console.log("totalSupply - ", totalSupply);
//         console.log("wethValueInUsd - ", wethValueInUsd);
//         console.log("wbtcValueInUsd - ", wbtcValueInUsd);

//         assert(totalSupply < wethValueInUsd + wbtcValueInUsd);
//     }
// }
