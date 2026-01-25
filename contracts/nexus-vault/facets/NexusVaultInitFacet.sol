// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { LibDiamond } from "../../diamond-common/libraries/LibDiamond.sol";
import { LibNexusVaultStorage } from "../libraries/LibNexusVaultStorage.sol";
import { LibNexusVaultAuth } from "../libraries/LibNexusVaultAuth.sol";
import "../errors/NexusVaultErrors.sol";

/**
 * @title NexusVaultInitFacet
 * @author BaseVol Team
 * @notice Initialization facet for NexusVault Diamond
 * @dev Called once during diamond deployment to set up initial state
 *
 * Initialization flow:
 * 1. Deploy Diamond with DiamondCutFacet
 * 2. Add all facets via diamondCut
 * 3. Call initialize() to set up vault state
 * 4. Call addInitialKeepers() if needed
 */
contract NexusVaultInitFacet {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when vault is successfully initialized
    event Initialized(
        address indexed asset,
        string name,
        string symbol,
        address indexed admin,
        address indexed feeRecipient
    );

    /// @notice Emitted when initial keepers are added
    event InitialKeepersAdded(address[] keepers);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the NexusVault
     * @dev Can only be called once. Must be called by diamond owner.
     *
     * @param _asset Underlying asset address (e.g., USDC)
     * @param _name Vault token name (e.g., "BaseVol Nexus Vault")
     * @param _symbol Vault token symbol (e.g., "bvNEXUS")
     * @param _admin Admin address for vault management
     * @param _feeRecipient Address to receive collected fees
     *
     * Requirements:
     * - Caller must be diamond owner
     * - Asset must be a valid ERC20 token
     * - Admin and fee recipient must be non-zero addresses
     * - Vault must not already be initialized
     */
    function initialize(
        address _asset,
        string calldata _name,
        string calldata _symbol,
        address _admin,
        address _feeRecipient
    ) external {
        // Only diamond owner can initialize
        LibDiamond.enforceIsContractOwner();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Prevent re-initialization by checking if asset is already set
        if (address(s.asset) != address(0)) {
            revert AlreadyInitialized();
        }

        // Validate inputs
        if (_asset == address(0)) revert InvalidVaultAddress();
        if (_admin == address(0)) revert Unauthorized();
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();

        // Validate asset is ERC20 by calling decimals
        uint8 assetDecimals;
        try IERC20Metadata(_asset).decimals() returns (uint8 dec) {
            assetDecimals = dec;
        } catch {
            revert NotERC4626Compliant(_asset);
        }

        // Set core vault state
        s.asset = IERC20(_asset);
        s.name = _name;
        s.symbol = _symbol;
        s.decimals = assetDecimals;

        // Set access control
        s.owner = LibDiamond.contractOwner();
        s.admin = _admin;

        // Set default fee configuration (all fees start at 0)
        s.feeConfig = LibNexusVaultStorage.FeeConfig({
            managementFee: 0,
            performanceFee: 0,
            depositFee: 0,
            withdrawFee: 0,
            feeRecipient: _feeRecipient
        });

        // Set default rebalance configuration
        s.rebalanceConfig = LibNexusVaultStorage.RebalanceConfig({
            rebalanceThreshold: 0.05e18, // 5% default threshold
            maxSlippage: 0.01e18, // 1% default max slippage
            cooldownPeriod: 1 hours, // 1 hour default cooldown
            lastRebalanceTime: 0
        });

        // Initialize fee timestamp
        s.lastFeeTimestamp = block.timestamp;

        // Initialize reentrancy guard
        LibNexusVaultAuth.initializeReentrancyGuard();

        emit Initialized(_asset, _name, _symbol, _admin, _feeRecipient);
    }

    /**
     * @notice Add initial keepers during setup
     * @dev Can only be called by diamond owner, typically right after initialize()
     *
     * @param _keepers Array of keeper addresses to add
     *
     * Requirements:
     * - Caller must be diamond owner
     * - Keeper addresses must be non-zero
     */
    function addInitialKeepers(address[] calldata _keepers) external {
        LibDiamond.enforceIsContractOwner();

        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        uint256 length = _keepers.length;
        for (uint256 i = 0; i < length; ) {
            address keeper = _keepers[i];
            if (keeper != address(0)) {
                // Check for duplicates
                bool exists = false;
                uint256 existingLength = s.keepers.length;
                for (uint256 j = 0; j < existingLength; ) {
                    if (s.keepers[j] == keeper) {
                        exists = true;
                        break;
                    }
                    unchecked {
                        ++j;
                    }
                }

                if (!exists) {
                    s.keepers.push(keeper);
                }
            }
            unchecked {
                ++i;
            }
        }

        emit InitialKeepersAdded(_keepers);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if vault has been initialized
     * @return True if vault is initialized
     */
    function isInitialized() external view returns (bool) {
        return address(LibNexusVaultStorage.layout().asset) != address(0);
    }

    /**
     * @notice Get initialization info
     * @return asset Underlying asset address
     * @return name Vault name
     * @return symbol Vault symbol
     * @return decimals Vault decimals
     * @return owner_ Contract owner
     * @return admin_ Admin address
     */
    function getInitInfo()
        external
        view
        returns (
            address asset,
            string memory name,
            string memory symbol,
            uint8 decimals,
            address owner_,
            address admin_
        )
    {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        return (
            address(s.asset),
            s.name,
            s.symbol,
            s.decimals,
            s.owner,
            s.admin
        );
    }
}
