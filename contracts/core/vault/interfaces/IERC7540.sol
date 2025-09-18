// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IERC7540
 * @notice Interface for ERC-7540 Asynchronous ERC-4626 Tokenized Vaults
 * @dev Extension of ERC-4626 with asynchronous deposit and redemption support
 */
interface IERC7540 is IERC4626, IERC165 {
  /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a deposit request is submitted
   * @param controller The address that will control the request
   * @param owner The address that owns the deposited assets
   * @param requestId The ID of the request
   * @param sender The address that initiated the request
   * @param assets The amount of assets requested for deposit
   */
  event DepositRequest(
    address indexed controller,
    address indexed owner,
    uint256 indexed requestId,
    address sender,
    uint256 assets
  );

  /**
   * @notice Emitted when a redemption request is submitted
   * @param controller The address that will control the request
   * @param owner The address that owns the shares to be redeemed
   * @param requestId The ID of the request
   * @param sender The address that initiated the request
   * @param shares The amount of shares requested for redemption
   */
  event RedeemRequest(
    address indexed controller,
    address indexed owner,
    uint256 indexed requestId,
    address sender,
    uint256 shares
  );

  /**
   * @notice Emitted when an operator is set or unset
   * @param controller The address setting the operator
   * @param operator The address being set as operator
   * @param approved Whether the operator is approved or not
   */
  event OperatorSet(address indexed controller, address indexed operator, bool approved);

  /*//////////////////////////////////////////////////////////////
                            REQUEST METHODS
    //////////////////////////////////////////////////////////////*/

  /**
   * @notice Submit a request for asynchronous deposit
   * @param assets The amount of assets to deposit
   * @param controller The address that will control the request
   * @param owner The address that owns the assets
   * @return requestId The ID of the request
   * @dev Transfers assets from owner to vault and places request in pending state
   */
  function requestDeposit(
    uint256 assets,
    address controller,
    address owner
  ) external returns (uint256 requestId);

  /**
   * @notice Submit a request for asynchronous redemption
   * @param shares The amount of shares to redeem
   * @param controller The address that will control the request
   * @param owner The address that owns the shares
   * @return requestId The ID of the request
   * @dev Transfers shares from owner to vault and places request in pending state
   */
  function requestRedeem(
    uint256 shares,
    address controller,
    address owner
  ) external returns (uint256 requestId);

  /*//////////////////////////////////////////////////////////////
                            VIEW METHODS
    //////////////////////////////////////////////////////////////*/

  /**
   * @notice Returns the amount of pending deposit assets for a controller
   * @param controller The address to check
   * @return The amount of pending deposit assets
   */
  function pendingDepositRequest(address controller) external view returns (uint256);

  /**
   * @notice Returns the amount of claimable deposit assets for a controller
   * @param controller The address to check
   * @return The amount of claimable deposit assets
   */
  function claimableDepositRequest(address controller) external view returns (uint256);

  /**
   * @notice Returns the amount of pending redemption shares for a controller
   * @param controller The address to check
   * @return The amount of pending redemption shares
   */
  function pendingRedeemRequest(address controller) external view returns (uint256);

  /**
   * @notice Returns the amount of claimable redemption shares for a controller
   * @param controller The address to check
   * @return The amount of claimable redemption shares
   */
  function claimableRedeemRequest(address controller) external view returns (uint256);

  /*//////////////////////////////////////////////////////////////
                            OPERATOR METHODS
    //////////////////////////////////////////////////////////////*/

  /**
   * @notice Set or unset an operator for the caller
   * @param operator The address to set as operator
   * @param approved Whether to approve or revoke the operator
   * @return success Whether the operation was successful
   */
  function setOperator(address operator, bool approved) external returns (bool);

  /**
   * @notice Check if an address is an operator for a controller
   * @param controller The address that owns the requests
   * @param operator The address to check for operator status
   * @return Whether the operator is approved
   */
  function isOperator(address controller, address operator) external view returns (bool);

  /*//////////////////////////////////////////////////////////////
                            ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

  /**
   * @notice Claim a deposit request
   * @param assets The amount of assets to claim
   * @param receiver The address to receive the shares
   * @param controller The address that controls the request
   * @return shares The amount of shares minted
   * @dev For async deposit vaults, this does not transfer assets to vault
   */
  function deposit(
    uint256 assets,
    address receiver,
    address controller
  ) external returns (uint256 shares);

  /**
   * @notice Claim a mint request
   * @param shares The amount of shares to claim
   * @param receiver The address to receive the shares
   * @param controller The address that controls the request
   * @return assets The amount of assets used
   * @dev For async deposit vaults, this does not transfer assets to vault
   */
  function mint(
    uint256 shares,
    address receiver,
    address controller
  ) external returns (uint256 assets);

  /**
   * @notice Claim a withdraw request
   * @param assets The amount of assets to claim
   * @param receiver The address to receive the assets
   * @param controller The address that controls the request
   * @return shares The amount of shares burned
   * @dev For async redeem vaults, this does not transfer shares to vault
   */
  function withdraw(
    uint256 assets,
    address receiver,
    address controller
  ) external returns (uint256 shares);

  /**
   * @notice Claim a redeem request
   * @param shares The amount of shares to claim
   * @param receiver The address to receive the assets
   * @param controller The address that controls the request
   * @return assets The amount of assets transferred
   * @dev For async redeem vaults, this does not transfer shares to vault
   */
  function redeem(
    uint256 shares,
    address receiver,
    address controller
  ) external returns (uint256 assets);
}
