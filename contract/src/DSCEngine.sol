// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralisedStableCoin.sol";
import {IVerifier} from "./Verifier.sol";

/**
 * @title DSCEngine
 * @author SuyashAlphaC
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * The system is designed to be overcollateralized at all times.
 * This contract integrates a ZK-Verifier to ensure that user actions (minting, redeeming)
 * maintain a healthy collateralization ratio before the state is updated on-chain.
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__ProofDoesNotMatch();

    ///////////////////
    // Types
    ///////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////
    // State Variables
    ///////////////////

    // --- CONSTANTS ---
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 50% liquidation threshold. A position can be liquidated if health factor is below this.
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators.
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // The minimum health factor for a position to be considered healthy.
    uint256 private constant PRECISION = 1e18; // 18 decimals of precision.
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // Precision adjustment for price feeds that use 8 decimals.
    uint256 private constant FEED_PRECISION = 1e8; // Standard precision for most USD price feeds from Chainlink.

    // --- IMMUTABLES ---
    /**
     * @dev Address of the DecentralizedStableCoin (DSC) token.
     */
    DecentralizedStableCoin private immutable i_dsc;
    /**
     * @dev Address of the ZK proof verifier contract.
     */
    IVerifier public immutable i_verifier;

    // --- STORAGE ---
    /**
     * @dev Mapping from collateral token address to its Chainlink price feed address.
     */
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    /**
     * @dev Mapping of user address to their deposited collateral amount for each token.
     */
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    /**
     * @dev Mapping of user address to the total amount of DSC they have minted.
     */
    mapping(address user => uint256 amount) private s_DSCMinted;
    /**
     * @dev Array of allowed collateral token addresses.
     */
    address[] private s_collateralTokens;

    ///////////////////
    // Events
    ///////////////////
    /**
     * @notice Emitted when a user deposits collateral.
     * @param user The address of the user who deposited.
     * @param token The address of the collateral token deposited.
     * @param amount The amount of collateral deposited.
     */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /**
     * @notice Emitted when a user's collateral is redeemed. Can be self-redeemed or through liquidation.
     * @param redeemFrom The address from which collateral was taken.
     * @param redeemTo The address to which collateral was sent.
     * @param token The address of the collateral token redeemed.
     * @param amount The amount of collateral redeemed.
     */
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);


    ///////////////////
    // Modifiers
    ///////////////////
    /**
     * @dev Reverts if the input amount is zero.
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    /**
     * @dev Reverts if the token is not in the allowed list of collaterals.
     */
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress,
        IVerifier _verifier
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
        i_verifier = _verifier;
    }

    ////////////////////////
    // External Functions
    ////////////////////////

    /**
     * @notice Deposits collateral and mints DSC in a single transaction.
     * @dev This function calculates the expected state (total DSC minted, total collateral value)
     * after the operation and requires a valid ZK proof of this state to proceed.
     * @param tokenCollateralAddress The address of the ERC20 token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of DSC to mint.
     * @param proof The ZK proof that verifies the health of the position after the operation.
     */
    function depositCollateralAndMintDscWithZK(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint,
        bytes memory proof
    )
        external
    {
        (uint256 initialDscMinted, uint256 initialCollateralValue) = _getAccountInformation(msg.sender);

        // 1. Calculate the expected state on-chain
        uint256 expectedTotalDscMinted = initialDscMinted + amountDscToMint;
        uint256 expectedCollateralValueInUsd = initialCollateralValue + _getUsdValue(tokenCollateralAddress, amountCollateral);

        bytes32[] memory publicInputs = new bytes32[](2);
        publicInputs[0] = bytes32(expectedTotalDscMinted);
        publicInputs[1] = bytes32(expectedCollateralValueInUsd);

        bool success = i_verifier.verify(proof, publicInputs);
        require(success, "DSCEngine: ZK proof is not valid");

        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDscWithZK( amountDscToMint);
    }


    /**
     * @notice Burns DSC and redeems a corresponding amount of collateral.
     * @dev Calculates the expected state after redemption and requires a valid ZK proof to proceed.
     * @param tokenCollateralAddress The address of the collateral to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC to burn.
     * @param proof The ZK proof verifying the final state.
     */
    function redeemCollateralForDscWithZK(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn,
        bytes memory proof
    ) external moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) {
        uint256 totalDscMinted = s_DSCMinted[msg.sender];
        if (totalDscMinted < amountDscToBurn) {
            revert DSCEngine__BreaksHealthFactor(0);
        }
        uint256 dscMintedAfterBurn = totalDscMinted - amountDscToBurn;
        uint256 collateralValueBeforeRedeem = getAccountCollateralValue(msg.sender);
        uint256 valueOfCollateralToRedeem = _getUsdValue(tokenCollateralAddress, amountCollateral);

        if (valueOfCollateralToRedeem > collateralValueBeforeRedeem) {
            revert DSCEngine__BreaksHealthFactor(0); // Not enough collateral
        }
        uint256 collateralValueInUsdAfterRedeem = collateralValueBeforeRedeem - valueOfCollateralToRedeem;

        bytes32[] memory publicInputs = new bytes32[](2);
        publicInputs[0] = bytes32(dscMintedAfterBurn);
        publicInputs[1] = bytes32(collateralValueInUsdAfterRedeem);

        bool success = i_verifier.verify(proof, publicInputs);
        if (!success) {
            revert DSCEngine__BreaksHealthFactor(0);
        }
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
    }

    /**
     * @notice Redeems collateral without burning any DSC.
     * @dev Requires a ZK proof that the position remains healthy after the withdrawal.
     * @param tokenCollateralAddress The address of the collateral to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param proof The ZK proof verifying the final state.
     */
    function redeemCollateralWithZK(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        bytes memory proof
    ) external moreThanZero(amountCollateral) nonReentrant isAllowedToken(tokenCollateralAddress) {
        uint256 totalDscMinted = s_DSCMinted[msg.sender];
        uint256 collateralValueBeforeRedeem = getAccountCollateralValue(msg.sender);
        uint256 valueOfCollateralToRedeem = _getUsdValue(tokenCollateralAddress, amountCollateral);

        if (valueOfCollateralToRedeem > collateralValueBeforeRedeem) {
            revert DSCEngine__BreaksHealthFactor(0); // Not enough collateral
        }
        uint256 collateralValueInUsdAfterRedeem = collateralValueBeforeRedeem - valueOfCollateralToRedeem;

        bytes32[] memory publicInputs = new bytes32[](2);
        publicInputs[0] = bytes32(totalDscMinted);
        publicInputs[1] = bytes32(collateralValueInUsdAfterRedeem);

        bool success = i_verifier.verify(proof, publicInputs);
        if (!success) {
            revert DSCEngine__BreaksHealthFactor(0);
        }
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
    }

    /**
     * @notice Burns DSC tokens to improve account health or pay back debt.
     * @dev Requires a ZK proof that the resulting state is valid. Collateral remains untouched.
     * @param amount The amount of DSC to burn.
     * @param proof The ZK proof verifying the final state.
     */
    function burnDscWithZK(uint256 amount, bytes memory proof) external moreThanZero(amount) {
        uint256 totalDscMinted = s_DSCMinted[msg.sender];
        if (totalDscMinted < amount) {
            revert DSCEngine__BreaksHealthFactor(0);
        }
        uint256 amountDscAfterBurn = totalDscMinted - amount;
        uint256 collateralValueInUsd = getAccountCollateralValue(msg.sender);
        bytes32[] memory publicInputs = new bytes32[](2);
        publicInputs[0] = bytes32(amountDscAfterBurn);
        publicInputs[1] = bytes32(collateralValueInUsd);

        bool success = i_verifier.verify(proof, publicInputs);
        if (!success) {
            revert DSCEngine__BreaksHealthFactor(0);
        }

        _burnDsc(amount, msg.sender, msg.sender);
    }


    //////////////////////
    // Public Functions
    //////////////////////

    /**
     * @notice Mints DSC.
     * @dev This is an internal function called by `depositCollateralAndMintDscWithZK`. It should not be called directly
     * without a preceding ZK proof verification. The health factor check is handled off-chain and verified by the ZK proof.
     * @param amountDscToMint The amount of DSC to mint.
     */
    function mintDscWithZK(uint256 amountDscToMint) internal moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice Deposits collateral into the DSCEngine.
     * @dev This is an internal function called by `depositCollateralAndMintDscWithZK`. It does not check for health factor
     * as that is handled by the ZK proof verification in the calling function.
     * @param tokenCollateralAddress The address of the ERC20 token to deposit.
     * @param amountCollateral The amount to deposit.
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) internal moreThanZero(amountCollateral) nonReentrant isAllowedToken(tokenCollateralAddress) {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }


    ///////////////////////
    // Private Functions
    ///////////////////////
    /**
     * @dev Low-level function to redeem collateral.
     */
    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev Low-level function to burn DSC.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }


    //////////////////////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////////////////////

    /**
     * @dev Gets a user's account information.
     */
    function _getAccountInformation(
        address user
    ) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @dev Calculates the USD value of a given amount of a token.
     */
    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        uint8 decimals = priceFeed.decimals();
        uint256 priceWithDecimals = (uint256(price) * PRECISION) / (10 ** decimals);
        return (priceWithDecimals * amount) / PRECISION;
    }


    /////////////////////////////////////////
    // External & Public View & Pure Functions
    /////////////////////////////////////////

    /**
     * @notice Retrieves the total DSC minted and total collateral value in USD for a user.
     * @param user The address of the user.
     * @return totalDscMinted The total amount of DSC minted by the user.
     * @return collateralValueInUsd The total value of all collateral deposited by the user, in USD.
     */
    function getAccountInformation(
        address user
    ) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        return _getAccountInformation(user);
    }

    /**
     * @notice Converts a token amount to its equivalent value in USD.
     * @param token The address of the ERC20 token.
     * @param amount The amount of the token (in wei).
     * @return The USD value of the token amount (in wei).
     */
    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    /**
     * @notice Gets the collateral balance of a specific token for a user.
     * @param user The address of the user.
     * @param token The address of the collateral token.
     * @return The amount of the specified collateral token deposited by the user.
     */
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    /**
     * @notice Calculates the total value of all collateral a user has deposited.
     * @param user The address of the user.
     * @return totalCollateralValueInUsd The total value in USD.
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd = totalCollateralValueInUsd + _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @notice Converts a USD value to its equivalent amount of a specific token.
     * @param token The address of the ERC20 token.
     * @param usdAmountInWei The amount in USD (in wei).
     * @return The equivalent amount of the token (in wei).
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    // --- Getter Functions ---

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}