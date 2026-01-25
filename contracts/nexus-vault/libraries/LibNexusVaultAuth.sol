// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { LibNexusVaultStorage } from "./LibNexusVaultStorage.sol";
import "../errors/NexusVaultErrors.sol";

/**
 * @title LibNexusVaultAuth
 * @author BaseVol Team
 * @notice Access control library for NexusVault Diamond
 * @dev Provides reusable authorization checks for all facets
 */
library LibNexusVaultAuth {
    /*//////////////////////////////////////////////////////////////
                            ROLE ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reverts if caller is not the owner
     * @dev Owner has highest privilege level
     */
    function enforceIsOwner() internal view {
        if (msg.sender != LibNexusVaultStorage.layout().owner) {
            revert OnlyOwner();
        }
    }

    /**
     * @notice Reverts if caller is not admin or owner
     * @dev Admin can configure vaults, fees, and keepers
     */
    function enforceIsAdmin() internal view {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        if (msg.sender != s.admin && msg.sender != s.owner) {
            revert OnlyAdmin();
        }
    }

    /**
     * @notice Reverts if caller is not a keeper, admin, or owner
     * @dev Keepers can trigger rebalancing and fee collection
     */
    function enforceIsKeeper() internal view {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // Owner and admin always have keeper privileges
        if (msg.sender == s.owner || msg.sender == s.admin) {
            return;
        }

        // Check keeper list
        address[] storage keepers = s.keepers;
        uint256 length = keepers.length;
        for (uint256 i = 0; i < length; ) {
            if (keepers[i] == msg.sender) {
                return;
            }
            unchecked {
                ++i;
            }
        }

        revert OnlyKeeper();
    }

    /*//////////////////////////////////////////////////////////////
                            ROLE QUERIES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if an address is the owner
     * @param account Address to check
     * @return True if account is owner
     */
    function isOwner(address account) internal view returns (bool) {
        return account == LibNexusVaultStorage.layout().owner;
    }

    /**
     * @notice Check if an address is admin or owner
     * @param account Address to check
     * @return True if account is admin or owner
     */
    function isAdmin(address account) internal view returns (bool) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        return account == s.admin || account == s.owner;
    }

    /**
     * @notice Check if an address is a keeper (or admin/owner)
     * @param account Address to check
     * @return True if account is a keeper, admin, or owner
     */
    function isKeeper(address account) internal view returns (bool) {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        if (account == s.owner || account == s.admin) {
            return true;
        }

        address[] storage keepers = s.keepers;
        uint256 length = keepers.length;
        for (uint256 i = 0; i < length; ) {
            if (keepers[i] == account) {
                return true;
            }
            unchecked {
                ++i;
            }
        }

        return false;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE CHECKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reverts if vault is paused
     */
    function enforceNotPaused() internal view {
        if (LibNexusVaultStorage.layout().paused) {
            revert VaultPaused();
        }
    }

    /**
     * @notice Reverts if vault is not paused
     */
    function enforcePaused() internal view {
        if (!LibNexusVaultStorage.layout().paused) {
            revert NotPaused();
        }
    }

    /**
     * @notice Reverts if vault is shutdown
     */
    function enforceNotShutdown() internal view {
        if (LibNexusVaultStorage.layout().shutdown) {
            revert VaultShutdown();
        }
    }

    /**
     * @notice Reverts if vault is paused or shutdown (for deposits)
     */
    function enforceOperational() internal view {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();
        if (s.paused) revert VaultPaused();
        if (s.shutdown) revert VaultShutdown();
    }

    /**
     * @notice Reverts if vault is paused (withdrawals allowed when shutdown)
     */
    function enforceWithdrawable() internal view {
        if (LibNexusVaultStorage.layout().paused) {
            revert VaultPaused();
        }
        // Note: shutdown state allows withdrawals
    }

    /*//////////////////////////////////////////////////////////////
                            REENTRANCY GUARD
    //////////////////////////////////////////////////////////////*/

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /**
     * @notice Initialize reentrancy guard state
     * @dev Called during vault initialization
     */
    function initializeReentrancyGuard() internal {
        LibNexusVaultStorage.layout().reentrancyStatus = NOT_ENTERED;
    }

    /**
     * @notice Enter reentrancy guard - reverts if already entered
     */
    function nonReentrantBefore() internal {
        LibNexusVaultStorage.Layout storage s = LibNexusVaultStorage.layout();

        // On first call, status will be 0, treat as NOT_ENTERED
        if (s.reentrancyStatus == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        s.reentrancyStatus = ENTERED;
    }

    /**
     * @notice Exit reentrancy guard
     */
    function nonReentrantAfter() internal {
        LibNexusVaultStorage.layout().reentrancyStatus = NOT_ENTERED;
    }
}
