//SPDX-License-Identifier:MIT

pragma solidity ^0.8.20;
import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {HonkVerifier} from "../../src/Verifier.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import {DeployDSC} from "../../script/DeployDSCEngine.s.sol";

contract DSCEngineTest is Test {
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    address public user = makeAddr("user");
    DeployDSC public deployer;
    HonkVerifier public  verifier;
    HelperConfig public config;
    DSCEngine public engine;
    DecentralizedStableCoin public dsc;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 1000 ether;
   
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    function setUp() public {
        deployer = new DeployDSC();
        ( dsc,engine, config, verifier) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config.activeNetworkConfig();
        console.log("Done Here!!");
        vm.deal(user, STARTING_USER_BALANCE);
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    function _getProof(uint256 totalDscMinted, uint256 collateralValueInUsd) public returns(bytes memory proof, bytes32[] memory publicInput) {
        string[] memory input = new string[](5);
        input[0] = "npx";
        input[1] = "tsx";
        input[2] = "js-scripts/generateProof.js";
        input[3] = vm.toString(totalDscMinted);
        input[4] = vm.toString(collateralValueInUsd);

        bytes memory  result = vm.ffi(input);
        (proof, publicInput) = abi.decode(result, (bytes, bytes32[])); 
    }


    // #################
    // ## Modifiers   ##
    // #################

     modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    modifier depositedAndMinted() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        
        // ZK Proof Generation for Deposit & Mint
        (uint256 initialDscMinted, uint256 initialCollateralValue) = engine.getAccountInformation(user);
        uint256 expectedTotalDscMinted = initialDscMinted + amountToMint;
        uint256 expectedCollateralValueInUsd = initialCollateralValue + engine.getUsdValue(weth, amountCollateral);
        (bytes memory proof, ) = _getProof(expectedTotalDscMinted, expectedCollateralValueInUsd);
        
        engine.depositCollateralAndMintDscWithZK(weth, amountCollateral, amountToMint, proof);
        vm.stopPrank();
        _;
    }
    // #################
    // ## Tests       ##
    // #################

    // #################################
    // ## DepositCollateralAndMintDSC ##
    // #################################

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(user);
        uint256 expectedDepositedAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }


     function testDepositCollateralAndMintDscWithZK() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);

        (uint256 initialDscMinted, uint256 initialCollateralValue) = engine.getAccountInformation(user);
        
        uint256 expectedTotalDscMinted = initialDscMinted + amountToMint;
        uint256 expectedCollateralValueInUsd = initialCollateralValue + engine.getUsdValue(weth, amountCollateral);

        console.log("Generating proof for DSC Minted: %s", expectedTotalDscMinted);
        console.log("Generating proof for Collateral Value (USD): %s", expectedCollateralValueInUsd);
        (bytes memory proof , ) = _getProof(expectedTotalDscMinted, expectedCollateralValueInUsd);
    
        engine.depositCollateralAndMintDscWithZK(weth, amountCollateral, amountToMint, proof);
        vm.stopPrank();

        assertEq(engine.getCollateralBalanceOfUser(user, weth), amountCollateral, "Collateral not deposited");
        assertEq(dsc.balanceOf(user), amountToMint, "DSC not minted");

    }

    function testRevertIfMintingWithInvalidProof() public  {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        
        (bytes memory proof, ) = _getProof(0, 0);

        vm.expectRevert();
        engine.depositCollateralAndMintDscWithZK(weth, amountCollateral, amountToMint, proof);
        vm.stopPrank();
    }

    // #################################
    // ## redeemCollateralForDscWithZK ##
    // #################################

    function testCanRedeemCollateralAndBurnDsc() public depositedAndMinted {
        // State before redeeming
        uint256 initialUserWethBalance = ERC20Mock(weth).balanceOf(user);
        uint256 initialUserDscBalance = dsc.balanceOf(user);

        // Define amounts to redeem/burn
        uint256 amountToRedeem = amountCollateral / 2;
        uint256 amountToBurn = amountToMint / 2;

        vm.startPrank(user);
        dsc.approve(address(engine), amountToBurn);

        // Calculate expected state for ZK proof
        uint256 expectedDscMinted = initialUserDscBalance - amountToBurn;
        uint256 collateralValueBefore = engine.getAccountCollateralValue(user);
        uint256 valueOfCollateralToRedeem = engine.getUsdValue(weth, amountToRedeem);
        uint256 expectedCollateralValue = collateralValueBefore - valueOfCollateralToRedeem;

        (bytes memory proof, bytes32[] memory publicInputs) = _getProof(expectedDscMinted, expectedCollateralValue);

        // Execute the function
        engine.redeemCollateralForDscWithZK(weth, amountToRedeem, amountToBurn, proof);
        vm.stopPrank();

        // Assert final state
        assertEq(ERC20Mock(weth).balanceOf(user), initialUserWethBalance + amountToRedeem);
        assertEq(dsc.balanceOf(user), initialUserDscBalance - amountToBurn);
    }
    
    function testRevertIfRedeemForDscWithInvalidProof() public depositedAndMinted {
        uint256 amountToRedeem = amountCollateral / 2;
        uint256 amountToBurn = amountToMint / 2;

        vm.startPrank(user);
        dsc.approve(address(engine), amountToBurn);
        
        
        (bytes memory proof, bytes32[] memory publicInputs) = _getProof(0, 0);

        vm.expectRevert();
        engine.redeemCollateralForDscWithZK(weth, amountToRedeem, amountToBurn, proof);
        vm.stopPrank();
    }


    // ###########################
    // ## redeemCollateralWithZK ##
    // ###########################

    function testCanRedeemCollateralWithoutBurningDsc() public depositedAndMinted {
        uint256 initialUserWethBalance = ERC20Mock(weth).balanceOf(user);
        uint256 amountToRedeem = amountCollateral / 2;

        console.log("Initial User Weth Balance : " , initialUserWethBalance);
        console.log("Amount To Redeem : ", amountToRedeem);

        vm.startPrank(user);
        
        // Calculate expected state for ZK proof
        uint256 totalDscMinted = dsc.balanceOf(user);
        uint256 collateralValueBefore = engine.getAccountCollateralValue(user);
        uint256 valueOfCollateralToRedeem = engine.getUsdValue(weth, amountToRedeem);
        uint256 expectedCollateralValue = collateralValueBefore - valueOfCollateralToRedeem;

        console.log("Details : totalDSCMinted : " , totalDscMinted);
        console.log("collateralValueBefore Redeem : ", collateralValueBefore);
        console.log("Collateral Value to Redeem : ", valueOfCollateralToRedeem);
        console.log("Expected Collateral Value : ", expectedCollateralValue);

        (bytes memory proof, ) = _getProof(totalDscMinted, expectedCollateralValue);
        
        bytes32[] memory publicInputs = new bytes32[](2);
        publicInputs[0] = bytes32(totalDscMinted);
        publicInputs[1] = bytes32(expectedCollateralValue);

        engine.redeemCollateralWithZK(weth, amountToRedeem, proof);
        vm.stopPrank();

        assertEq(ERC20Mock(weth).balanceOf(user), initialUserWethBalance + amountToRedeem);
        assertEq(engine.getCollateralBalanceOfUser(user, weth), amountCollateral - amountToRedeem);
    }
    
    // ###################
    // ## burnDscWithZK ##
    // ###################

    function testCanBurnDsc() public depositedAndMinted {
        uint256 initialUserDscBalance = dsc.balanceOf(user);
        uint256 amountToBurn = amountToMint / 2;
        
        vm.startPrank(user);
        dsc.approve(address(engine), amountToBurn);

        // Calculate expected state for ZK proof
        uint256 expectedDscMinted = initialUserDscBalance - amountToBurn;
        uint256 collateralValueInUsd = engine.getAccountCollateralValue(user);

        (bytes memory proof, ) = _getProof(expectedDscMinted, collateralValueInUsd);

        bytes32[] memory publicInputs = new bytes32[](2);
        publicInputs[0] = bytes32(expectedDscMinted);
        publicInputs[1] = bytes32(collateralValueInUsd);
        
        engine.burnDscWithZK(amountToBurn, proof);
        vm.stopPrank();

        assertEq(dsc.balanceOf(user), initialUserDscBalance - amountToBurn);
        assertEq(engine.getCollateralBalanceOfUser(user, weth), amountCollateral); // Collateral should be untouched
    }
    
    function testRevertIfBurnMoreDscThanMinted() public depositedAndMinted {
        uint256 amountToBurn = amountToMint + 1 ether;
        vm.startPrank(user);
        dsc.approve(address(engine), amountToBurn);

        uint256 collateralValueInUsd = engine.getAccountCollateralValue(user);

        // This proof generation would ideally happen off-chain
        // For the test, we know it will revert before the proof is even checked
        (bytes memory proof, ) = _getProof(0, collateralValueInUsd); 

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        engine.burnDscWithZK(amountToBurn, proof);
        vm.stopPrank();
    }


    // ######################
    // ## Getter Functions ##
    // ######################
    
    function testGetters() public view {
        assertEq(engine.getLiquidationThreshold(), LIQUIDATION_THRESHOLD);
        assertEq(engine.getLiquidationBonus(), 10);
        assertEq(engine.getPrecision(), 1e18);
        assertEq(address(engine.getDsc()), address(dsc));
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);
    }
}
    

