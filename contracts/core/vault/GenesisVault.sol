// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
pragma abicoder v2;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { GenesisManagedVault } from "./GenesisManagedVault.sol";
import { GenesisVaultStorage } from "./storage/GenesisVaultStorage.sol";
import { IGenesisVaultErrors } from "./errors/GenesisVaultErrors.sol";
import { IGenesisStrategy } from "./interfaces/IGenesisStrategy.sol";
import { IERC7540 } from "./interfaces/IERC7540.sol";

contract GenesisVault is Initializable, GenesisManagedVault, IERC7540 {
  using Math for uint256;
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  uint256 constant MAX_COST = 0.10 ether; // 10%

  event Shutdown(address account);
  event AdminUpdated(address indexed account, address indexed newAdmin);
  event StrategyUpdated(address account, address newStrategy);
  event EntryCostUpdated(address account, uint256 newEntryCost);
  event ExitCostUpdated(address account, uint256 newExitCost);
  event MaxCostsUpdated(address account, uint256 newMaxEntryCost, uint256 newMaxExitCost);
  event PriorityProviderUpdated(address account, address newPriorityProvider);
  event VaultState(uint256 indexed totalAssets, uint256 indexed totalSupply);
  event PrioritizedAccountAdded(address indexed account);
  event PrioritizedAccountRemoved(address indexed account);

  // ERC7540 Events (use OpenZeppelin's Withdraw/Redeem events)

  modifier onlyAdmin() {
    if (_msgSender() != admin()) {
      revert OnlyAdmin();
    }
    _;
  }

  function initialize(
    address asset_,
    uint256 entryCost_,
    uint256 exitCost_,
    string calldata name_,
    string calldata symbol_
  ) external initializer {
    __GenesisManagedVault_init(msg.sender, asset_, name_, symbol_);
    require(entryCost_ <= MAX_COST, "Entry cost too high");
    require(exitCost_ <= MAX_COST, "Exit cost too high");

    _setEntryCost(entryCost_);
    _setExitCost(exitCost_);
  }

  /*//////////////////////////////////////////////////////////////
                            ERC165 SUPPORT
    //////////////////////////////////////////////////////////////*/

  /// @notice ERC165 interface support
  function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
    return
      interfaceId == type(IERC7540).interfaceId ||
      interfaceId == type(IERC4626).interfaceId ||
      interfaceId == type(IERC20).interfaceId ||
      interfaceId == type(IERC165).interfaceId;
  }

  /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS   
    //////////////////////////////////////////////////////////////*/

  /// @notice Configures the admin.
  ///
  /// @param account The address of new admin.
  /// A zero address means disabling admin functions.
  function setAdmin(address account) external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    $.admin = account;
    emit AdminUpdated(_msgSender(), account);
  }

  /// @notice Configures the strategy.
  /// Note:
  /// - Approve new strategy to manage asset of this vault infinitely.
  /// - If there is an old strategy, revoke its asset approval after stopping the strategy.
  function setStrategy(address _strategy) external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    IERC20 _asset = IERC20(asset());
    address prevStrategy = strategy();

    if (prevStrategy != address(0)) {
      IGenesisStrategy(prevStrategy).stop();
      _asset.approve(prevStrategy, 0);
    }

    require(_strategy != address(0));
    if (
      IGenesisStrategy(_strategy).asset() != address(_asset) ||
      IGenesisStrategy(_strategy).vault() != address(this)
    ) {
      revert InvalidStrategy();
    }

    $.strategy = _strategy;
    _asset.approve(_strategy, type(uint256).max);

    emit StrategyUpdated(_msgSender(), _strategy);
  }

  /// @notice Configures new entry/exit cost setting.
  function setEntryAndExitCost(uint256 newEntryCost, uint256 newExitCost) external onlyAdmin {
    _setEntryCost(newEntryCost);
    _setExitCost(newExitCost);
  }

  /// @notice Adds a prioritized account (only owner can call)
  function addPrioritizedAccount(address account) external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    // Check if already exists
    for (uint256 i = 0; i < $.prioritizedAccounts.length; i++) {
      if ($.prioritizedAccounts[i] == account) {
        revert AccountAlreadyPrioritized();
      }
    }
    $.prioritizedAccounts.push(account);
    emit PrioritizedAccountAdded(account);
  }

  /// @notice Removes a prioritized account (only owner can call)
  function removePrioritizedAccount(address account) external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 length = $.prioritizedAccounts.length;
    for (uint256 i = 0; i < length; i++) {
      if ($.prioritizedAccounts[i] == account) {
        // Move last element to current position and pop
        $.prioritizedAccounts[i] = $.prioritizedAccounts[length - 1];
        $.prioritizedAccounts.pop();
        emit PrioritizedAccountRemoved(account);
        return;
      }
    }
    revert AccountNotPrioritized();
  }

  /// @notice Shutdown vault, where all deposit/mint are disabled while withdraw/redeem are still available.
  function shutdown() external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    $.shutdown = true;
    IGenesisStrategy(strategy()).stop();
    emit Shutdown(_msgSender());
  }

  /// @notice Pauses Vault temporarily so that deposit and withdraw functions are disabled.
  /// This function is callable only by the admin
  /// and is used if some unexpected behaviors from external protocols are spotted
  /// by the admin.
  ///
  /// @param stopStrategy True means stopping strategy, otherwise pausing strategy.
  function pause(bool stopStrategy) external onlyAdmin whenNotPaused {
    if (stopStrategy) {
      IGenesisStrategy(strategy()).stop();
    } else {
      IGenesisStrategy(strategy()).pause();
    }
    _pause();
  }

  /// @dev Unpauses Vault so that deposit and withdraw functions are enabled again.
  /// This function is callable only by the admin.
  function unpause() external onlyAdmin whenPaused {
    IGenesisStrategy(strategy()).unpause();
    _unpause();
  }

  /// @notice Sweep vault when nothing is happening.
  ///
  /// @param receiver The address who will receive idle assets.
  function sweep(address receiver) external onlyOwner {
    // 1. all shares should be redeemed.
    // 2. utilized assets should be zero that means all requests have been processed.
    // 3. All assets should be withdrawn from strategy and no pending requests should remain.
    require(
      totalSupply() == 0 &&
        IGenesisStrategy(strategy()).utilizedAssets() == 0 &&
        totalPendingWithdraw() == 0
    );

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: sweep ERC7540 pending states if needed
    // Note: In normal operation, these should already be zero

    // sweep prioritized accounts array
    delete $.prioritizedAccounts;

    // sweep idle assets
    IERC20(asset()).safeTransfer(receiver, idleAssets());
  }

  function harvestPerformanceFee() external {
    if (_msgSender() != strategy()) {
      revert CallerNotStrategy();
    }
    _harvestPerformanceFeeShares();
  }

  /*//////////////////////////////////////////////////////////////
                          ERC7540 OPERATOR SYSTEM
    //////////////////////////////////////////////////////////////*/

  /// @notice Set or unset an operator for the caller
  /// @param operator The address to set as operator
  /// @param approved Whether to approve or revoke the operator
  /// @return success Whether the operation was successful
  function setOperator(address operator, bool approved) external override returns (bool) {
    GenesisVaultStorage.layout().operators[_msgSender()][operator] = approved;
    emit OperatorSet(_msgSender(), operator, approved);
    return true;
  }

  /// @notice Check if an address is an operator for a controller
  /// @param controller The address that owns the requests
  /// @param operator The address to check for operator status
  /// @return Whether the operator is approved
  function isOperator(address controller, address operator) external view override returns (bool) {
    return GenesisVaultStorage.layout().operators[controller][operator];
  }

  /// @dev Modifier for operator access control
  modifier onlyControllerOrOperator(address controller) {
    require(
      _msgSender() == controller ||
        GenesisVaultStorage.layout().operators[controller][_msgSender()],
      "GenesisVault: not authorized"
    );
    _;
  }

  /*//////////////////////////////////////////////////////////////
                          ERC7540 ASYNC DEPOSIT LOGIC
    //////////////////////////////////////////////////////////////*/

  /// @notice Submit a request for asynchronous deposit
  /// @param assets The amount of assets to deposit
  /// @param controller The address that will control the request
  /// @param owner The address that owns the assets
  /// @return requestId The ID of the request
  function requestDeposit(
    uint256 assets,
    address controller,
    address owner
  ) external override returns (uint256 requestId) {
    require(assets > 0, "GenesisVault: zero assets");
    require(!paused() && !isShutdown(), "GenesisVault: vault not active");

    // ERC7540: owner MUST equal msg.sender unless owner has approved msg.sender as operator
    require(
      _msgSender() == owner || GenesisVaultStorage.layout().operators[owner][_msgSender()],
      "GenesisVault: not authorized"
    );

    // Essential: Validate against deposit limits
    uint256 maxDepositAmount = maxDeposit(owner);
    require(assets <= maxDepositAmount, "GenesisVault: deposit exceeds limit");

    // Transfer assets to vault
    IERC20(asset()).safeTransferFrom(owner, address(this), assets);

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    requestId = $.nextRequestId++;

    $.depositRequests[requestId] = GenesisVaultStorage.DepositRequest({
      assets: assets,
      controller: controller,
      owner: owner,
      timestamp: block.timestamp,
      isClaimed: false
    });

    $.pendingDepositAssets[controller] += assets;
    $.accRequestedDepositAssets += assets;

    emit DepositRequest(controller, owner, requestId, _msgSender(), assets);

    // Auto-process if possible
    processPendingDepositRequests();

    return requestId;
  }

  /// @notice Process pending deposit requests with available capacity - Pure Pool O(1)
  /// @return The assets processed into claimable state
  function processPendingDepositRequests() public returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    uint256 availableCapacity = _calculateAvailableDepositCapacity();
    if (availableCapacity == 0) return 0;

    uint256 pendingAssets = $.accRequestedDepositAssets - $.processedDepositAssets;
    uint256 assetsToProcess = Math.min(availableCapacity, pendingAssets);

    if (assetsToProcess > 0) {
      $.processedDepositAssets += assetsToProcess;
      // Pure Pool: No individual request processing needed!
      // Claimable amounts are calculated dynamically in _calculateClaimableDepositAssets
    }

    return assetsToProcess;
  }

  /// @notice Returns the amount of pending deposit assets for a controller
  function pendingDepositRequest(address controller) external view override returns (uint256) {
    return GenesisVaultStorage.layout().pendingDepositAssets[controller];
  }

  /// @notice Returns the amount of claimable deposit assets for a controller
  /// @dev Pure Pool: Calculates claimable assets dynamically using proportional shares
  function claimableDepositRequest(address controller) external view override returns (uint256) {
    return _calculateClaimableDepositAssets(controller);
  }

  /*//////////////////////////////////////////////////////////////
                          ASYNC WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

  /// @notice Returns the maximum amount of the underlying asset that can be
  /// requested to withdraw from the owner balance in the Vault,
  /// through a requestRedeem call (ERC7540 uses requestRedeem for both)
  function maxRequestWithdraw(address owner) public view returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Return max assets based on owner's shares (for redeem requests)
    uint256 shares = balanceOf(owner);
    return _convertToAssets(shares, Math.Rounding.Floor);
  }

  /// @notice Returns the maximum amount of Vault shares that can be
  /// requested to redeem from the owner balance in the Vault,
  /// through a requestRedeem call.
  function maxRequestRedeem(address owner) public view returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Return owner's share balance for redeem requests
    return balanceOf(owner);
  }

  /// @notice ERC7540 - Returns max assets for requestDeposit (same as maxDeposit)
  function maxRequestDeposit(address owner) public view returns (uint256) {
    return maxDeposit(owner);
  }

  /// @notice ERC7540 - Returns max shares for immediate withdraw (claimable only)
  function maxClaimableWithdraw(address controller) public view returns (uint256) {
    return _calculateClaimableRedeemAssets(controller);
  }

  /// @notice ERC7540 - Returns max shares for immediate redeem (claimable only)
  function maxClaimableRedeem(address controller) public view returns (uint256) {
    return _calculateClaimableRedeemShares(controller);
  }

  function _setEntryCost(uint256 value) internal {
    require(value <= MAX_COST, "Entry cost exceeds maximum");
    if (entryCost() != value) {
      GenesisVaultStorage.layout().entryCost = value;
      emit EntryCostUpdated(_msgSender(), value);
    }
  }

  function _setExitCost(uint256 value) internal {
    require(value <= MAX_COST, "Exit cost exceeds maximum");
    if (exitCost() != value) {
      GenesisVaultStorage.layout().exitCost = value;
      emit ExitCostUpdated(_msgSender(), value);
    }
  }

  /// @notice ERC7540 redeem request with priority support
  /// @param shares The amount of shares to redeem
  /// @param controller The address that will control the request
  /// @param owner The address that owns the shares
  /// @return requestId The ID of the request
  function requestRedeem(
    uint256 shares,
    address controller,
    address owner
  ) external override returns (uint256 requestId) {
    require(shares > 0, "GenesisVault: zero shares");
    require(!paused() && !isShutdown(), "GenesisVault: vault not active");

    // ERC7540: Redeem Request approval may come from ERC-20 approval OR operator approval
    if (_msgSender() != owner) {
      bool hasOperatorApproval = GenesisVaultStorage.layout().operators[owner][_msgSender()];
      if (!hasOperatorApproval) {
        _spendAllowance(owner, _msgSender(), shares);
      }
      // Note: If operator, no allowance deduction per ERC7540 spec
    }
    _burn(owner, shares);

    // 2. Check priority status
    bool isPrioritizedAccount = isPrioritized(owner);

    // 3. Create request
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    requestId = $.nextRequestId++;

    uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);

    $.redeemRequests[requestId] = GenesisVaultStorage.RedeemRequest({
      shares: shares,
      assets: assets,
      controller: controller,
      owner: owner,
      timestamp: block.timestamp,
      isPrioritized: isPrioritizedAccount,
      isProcessed: false
    });

    // 4. Update priority-based state
    if (isPrioritizedAccount) {
      $.prioritizedAccRequestedRedeemAssets += assets;
    } else {
      $.accRequestedRedeemAssets += assets;
    }

    // 5. Update pending state
    $.pendingRedeemShares[controller] += shares;
    $.pendingRedeemAssets[controller] += assets;

    emit RedeemRequest(controller, owner, requestId, _msgSender(), shares);

    // 6. Attempt automatic processing
    processRedeemRequests();

    return requestId;
  }

  /// @notice Pure Pool-based redeem processing - O(1) complexity
  /// @dev Processes pending redemptions using pure pool mathematics without individual request iteration
  function processRedeemRequests() public returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    uint256 _idleAssets = idleAssets();
    if (_idleAssets == 0) return 0;

    uint256 totalProcessed = 0;

    // O(1) Priority Pool Processing
    uint256 priorityPending = $.prioritizedAccRequestedRedeemAssets -
      $.prioritizedProcessedRedeemAssets;
    uint256 priorityToProcess = Math.min(_idleAssets, priorityPending);

    if (priorityToProcess > 0) {
      $.prioritizedProcessedRedeemAssets += priorityToProcess;
      totalProcessed += priorityToProcess;
      _idleAssets -= priorityToProcess;

      // Pure pool: No individual request iteration needed
      // All controllers with priority requests become proportionally claimable
    }

    //  O(1) Normal Pool Processing
    uint256 normalPending = $.accRequestedRedeemAssets - $.processedRedeemAssets;
    uint256 normalToProcess = Math.min(_idleAssets, normalPending);

    if (normalToProcess > 0) {
      $.processedRedeemAssets += normalToProcess;
      totalProcessed += normalToProcess;

      // Pure pool: No individual request iteration needed
      // All controllers with normal requests become proportionally claimable
    }

    //  In pure pool system, individual request processing is eliminated
    // Controllers can claim their proportional share based on:
    // - Their pending amounts
    // - Total processed amounts for their priority group
    // - Current pool ratios

    return totalProcessed;
  }

  /// @notice Returns the amount of pending redemption shares for a controller
  function pendingRedeemRequest(address controller) external view override returns (uint256) {
    return GenesisVaultStorage.layout().pendingRedeemShares[controller];
  }

  /// @notice Returns the amount of claimable redemption shares for a controller
  /// @dev Pure Pool calculation - computed dynamically based on proportional share
  function claimableRedeemRequest(address controller) external view override returns (uint256) {
    return _calculateClaimableRedeemShares(controller);
  }

  /// @notice Calculate claimable redeem shares dynamically using pure pool mathematics
  function _calculateClaimableRedeemShares(address controller) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    uint256 pendingShares = $.pendingRedeemShares[controller];
    if (pendingShares == 0) return 0;

    //  Corrected Pure Pool Calculation
    bool isPriority = isPrioritized(controller);

    if (isPriority) {
      uint256 totalPriorityRequested = $.prioritizedAccRequestedRedeemAssets;
      uint256 totalPriorityProcessed = $.prioritizedProcessedRedeemAssets;
      uint256 totalPriorityClaimed = $.prioritizedClaimedRedeemAssets;

      // Available for claiming = processed - already claimed
      uint256 availableForClaim = totalPriorityProcessed - totalPriorityClaimed;
      if (availableForClaim == 0) return 0;

      // Total still pending = requested - claimed
      uint256 totalPending = totalPriorityRequested - totalPriorityClaimed;
      if (totalPending == 0) return 0;

      // Proportional calculation
      uint256 pendingAssets = $.pendingRedeemAssets[controller];
      uint256 claimableAssets = (pendingAssets * availableForClaim) / totalPending;
      return _convertToShares(claimableAssets, Math.Rounding.Floor);
    } else {
      uint256 totalNormalRequested = $.accRequestedRedeemAssets;
      uint256 totalNormalProcessed = $.processedRedeemAssets;
      uint256 totalNormalClaimed = $.claimedRedeemAssets;

      // Available for claiming = processed - already claimed
      uint256 availableForClaim = totalNormalProcessed - totalNormalClaimed;
      if (availableForClaim == 0) return 0;

      // Total still pending = requested - claimed
      uint256 totalPending = totalNormalRequested - totalNormalClaimed;
      if (totalPending == 0) return 0;

      // Proportional calculation
      uint256 pendingAssets = $.pendingRedeemAssets[controller];
      uint256 claimableAssets = (pendingAssets * availableForClaim) / totalPending;
      return _convertToShares(claimableAssets, Math.Rounding.Floor);
    }
  }

  /// @notice Tells if the owner is prioritized to withdraw.
  function isPrioritized(address owner) public view returns (bool) {
    address[] memory _prioritizedAccounts = prioritizedAccounts();
    for (uint256 i = 0; i < _prioritizedAccounts.length; i++) {
      if (_prioritizedAccounts[i] == owner) {
        return true;
      }
    }
    return false;
  }

  /// @notice The underlying asset amount in this vault that is free to withdraw or utilize.
  /// @dev ERC7540: Returns the vault's asset balance as idle assets since claims are immediate
  function idleAssets() public view returns (uint256) {
    //  ERC7540 Pure Pool System:
    // - Deposit requests: Assets are held in vault until processed into shares
    // - Redeem requests: Once processed, assets are immediately available for claiming
    // - When users call withdraw/redeem, assets are immediately transferred out
    // - No assets are "reserved" or locked in the vault
    //
    // Therefore, all assets in the vault are considered "idle" and available
    // for utilization by the strategy or processing new requests.

    return IERC20(asset()).balanceOf(address(this));
  }

  /// @notice ERC7540 - Returns total pending redeem assets (prioritized + normal)
  function totalPendingWithdraw() public view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    return
      $.prioritizedAccRequestedRedeemAssets +
      $.accRequestedRedeemAssets -
      $.prioritizedProcessedRedeemAssets -
      $.processedRedeemAssets;
  }

  /*//////////////////////////////////////////////////////////////
                             ERC7540 CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice ERC7540 deposit (claim from async request) - Pure Pool O(1)
  /// @param assets The amount of assets to claim
  /// @param receiver The address to receive the shares
  /// @param controller The address that controls the request
  /// @return shares The amount of shares minted
  function deposit(
    uint256 assets,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 shares) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    //  Pure Pool: Dynamic claimable calculation
    uint256 claimableAssets = _calculateClaimableDepositAssets(controller);
    require(claimableAssets >= assets, "GenesisVault: insufficient claimable assets");

    //  Pure Pool: Update pending and claimed amounts correctly
    $.pendingDepositAssets[controller] -= assets;
    $.claimedDepositAssets += assets;

    // Convert assets to shares and mint (assets are already in vault)
    shares = _convertToShares(assets, Math.Rounding.Floor);
    _mint(receiver, shares);

    //  ERC7540: Emit Deposit event with controller as first parameter
    emit Deposit(controller, receiver, assets, shares);
    emit VaultState(totalAssets(), totalSupply());
    return shares;
  }

  /// @notice ERC7540 mint (claim from async request) - Pure Pool O(1)
  /// @param shares The amount of shares to claim
  /// @param receiver The address to receive the shares
  /// @param controller The address that controls the request
  /// @return assets The amount of assets used
  function mint(
    uint256 shares,
    address receiver,
    address controller
  ) external onlyControllerOrOperator(controller) returns (uint256 assets) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    assets = _convertToAssets(shares, Math.Rounding.Ceil);

    //  Pure Pool: Dynamic claimable calculation
    uint256 claimableAssets = _calculateClaimableDepositAssets(controller);
    require(claimableAssets >= assets, "GenesisVault: insufficient claimable assets");

    //  Pure Pool: Update pending and claimed amounts correctly
    $.pendingDepositAssets[controller] -= assets;
    $.claimedDepositAssets += assets;

    // Mint shares (assets are already in vault)
    _mint(receiver, shares);

    //  ERC7540: Emit Deposit event with controller as first parameter
    emit Deposit(controller, receiver, assets, shares);
    emit VaultState(totalAssets(), totalSupply());
    return assets;
  }

  /// @notice ERC7540 withdraw with Pure Pool calculation
  function withdraw(
    uint256 assets,
    address receiver,
    address controller
  ) public override(ERC4626Upgradeable, IERC7540) returns (uint256 shares) {
    //  ERC7540: controller MUST be msg.sender unless controller has approved msg.sender as operator
    require(
      _msgSender() == controller ||
        GenesisVaultStorage.layout().operators[controller][_msgSender()],
      "GenesisVault: not authorized"
    );

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // 1. Pure Pool: Calculate claimable assets dynamically
    uint256 claimableAssets = _calculateClaimableRedeemAssets(controller);
    require(claimableAssets >= assets, "GenesisVault: insufficient claimable assets");

    // 2. Calculate shares
    shares = _convertToShares(assets, Math.Rounding.Ceil);

    // 3. Pure Pool: Deduct directly from pending amounts
    $.pendingRedeemAssets[controller] -= assets;
    $.pendingRedeemShares[controller] -= shares;

    // 4. Update pool state (adjust processed amounts)
    bool isPriority = isPrioritized(controller);
    if (isPriority) {
      $.prioritizedProcessedRedeemAssets -= assets;
    } else {
      $.processedRedeemAssets -= assets;
    }

    // 5. Transfer assets
    IERC20(asset()).safeTransfer(receiver, assets);

    emit Withdraw(_msgSender(), receiver, controller, assets, shares);
    return shares;
  }

  /// @notice Calculate claimable redeem assets using pure pool mathematics
  function _calculateClaimableRedeemAssets(address controller) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    uint256 pendingAssets = $.pendingRedeemAssets[controller];
    if (pendingAssets == 0) return 0;

    //  Corrected Pure Pool Calculation
    bool isPriority = isPrioritized(controller);

    if (isPriority) {
      uint256 totalPriorityRequested = $.prioritizedAccRequestedRedeemAssets;
      uint256 totalPriorityProcessed = $.prioritizedProcessedRedeemAssets;
      uint256 totalPriorityClaimed = $.prioritizedClaimedRedeemAssets;

      // Available for claiming = processed - already claimed
      uint256 availableForClaim = totalPriorityProcessed - totalPriorityClaimed;
      if (availableForClaim == 0) return 0;

      // Total still pending = requested - claimed
      uint256 totalPending = totalPriorityRequested - totalPriorityClaimed;
      if (totalPending == 0) return 0;

      return (pendingAssets * availableForClaim) / totalPending;
    } else {
      uint256 totalNormalRequested = $.accRequestedRedeemAssets;
      uint256 totalNormalProcessed = $.processedRedeemAssets;
      uint256 totalNormalClaimed = $.claimedRedeemAssets;

      // Available for claiming = processed - already claimed
      uint256 availableForClaim = totalNormalProcessed - totalNormalClaimed;
      if (availableForClaim == 0) return 0;

      // Total still pending = requested - claimed
      uint256 totalPending = totalNormalRequested - totalNormalClaimed;
      if (totalPending == 0) return 0;

      return (pendingAssets * availableForClaim) / totalPending;
    }
  }

  /// @notice ERC7540 redeem with Pure Pool calculation
  function redeem(
    uint256 shares,
    address receiver,
    address controller
  ) public override(ERC4626Upgradeable, IERC7540) returns (uint256 assets) {
    //  ERC7540: controller MUST be msg.sender unless controller has approved msg.sender as operator
    require(
      _msgSender() == controller ||
        GenesisVaultStorage.layout().operators[controller][_msgSender()],
      "GenesisVault: not authorized"
    );

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // 1. Pure Pool: Calculate claimable shares dynamically
    uint256 claimableShares = _calculateClaimableRedeemShares(controller);
    require(claimableShares >= shares, "GenesisVault: insufficient claimable shares");

    // 2. Calculate assets
    assets = _convertToAssets(shares, Math.Rounding.Floor);

    // 3. Pure Pool: Deduct directly from pending amounts
    $.pendingRedeemShares[controller] -= shares;
    $.pendingRedeemAssets[controller] -= assets;

    // 4. Update pool state (increase claimed amounts)
    bool isPriority = isPrioritized(controller);
    if (isPriority) {
      $.prioritizedClaimedRedeemAssets += assets;
    } else {
      $.claimedRedeemAssets += assets;
    }

    // 5. Transfer assets
    IERC20(asset()).safeTransfer(receiver, assets);

    emit Withdraw(_msgSender(), receiver, controller, assets, shares);
    return assets;
  }

  /*//////////////////////////////////////////////////////////////
                        ERC4626 FUNCTIONS (ERC7540 IMPLEMENTATION)
    //////////////////////////////////////////////////////////////*/

  /// @notice ERC4626 deposit - DEPRECATED, use requestDeposit instead
  /// @dev Reserve the execution cost not to affect other's share price.
  function deposit(
    uint256 /* assets */,
    address /* receiver */
  ) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    revert("DEPRECATED: Use requestDeposit() followed by deposit(assets, receiver, controller)");
  }

  /// @notice ERC4626 mint - DEPRECATED, use requestDeposit instead
  function mint(
    uint256 /* shares */,
    address /* receiver */
  ) public pure override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    revert("DEPRECATED: Use requestDeposit() followed by mint(shares, receiver, controller)");
  }

  /// @inheritdoc ERC4626Upgradeable
  function totalAssets()
    public
    view
    virtual
    override(ERC4626Upgradeable, IERC4626)
    returns (uint256 assets)
  {
    (, assets) = (idleAssets() + IGenesisStrategy(strategy()).utilizedAssets()).trySub(
      totalPendingWithdraw()
    );
    return assets;
  }

  /// @inheritdoc ERC4626Upgradeable
  function previewDeposit(
    uint256 assets
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    (uint256 shares, ) = _previewDepositWithCost(assets);
    return shares;
  }

  function _previewDepositWithCost(
    uint256 assets
  ) private view returns (uint256 shares, uint256 cost) {
    // calculate the amount of assets that will be utilized
    uint256 assetsToUtilize = _assetsToUtilize(assets);

    // apply entry fee only to the portion of assets that will be utilized
    if (assetsToUtilize > 0) {
      cost = _costOnTotal(assetsToUtilize, entryCost());
      assets -= cost;
    }

    shares = _convertToShares(assets, Math.Rounding.Floor);
    return (shares, cost);
  }

  /// @inheritdoc ERC4626Upgradeable
  function previewMint(
    uint256 shares
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    (uint256 assets, ) = _previewMintWithCost(shares);
    return assets;
  }

  function _previewMintWithCost(
    uint256 shares
  ) private view returns (uint256 assets, uint256 cost) {
    assets = _convertToAssets(shares, Math.Rounding.Ceil);
    // calculate the amount of assets that will be utilized
    uint256 assetsToUtilize = _assetsToUtilize(assets);

    // apply entry fee only to the portion of assets that will be utilized
    if (assetsToUtilize > 0) {
      cost = _costOnRaw(assetsToUtilize, entryCost());
      assets += cost;
    }
    return (assets, cost);
  }

  /// @notice ERC7540 - previewWithdraw MUST revert for async vaults
  function previewWithdraw(
    uint256 assets
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    assets; // silence unused parameter warning
    revert("ERC7540: previewWithdraw not supported for async vaults");
  }

  function _previewWithdrawWithCost(
    uint256 assets
  ) private view returns (uint256 shares, uint256 cost) {
    // calc the amount of assets that can not be withdrawn via idle
    uint256 assetsToDeutilize = _assetsToDeutilize(assets);

    // apply exit fee to assets that should be deutilized and add exit fee amount the asset amount
    if (assetsToDeutilize > 0) {
      cost = _costOnRaw(assetsToDeutilize, exitCost());
      assets += cost;
    }

    shares = _convertToShares(assets, Math.Rounding.Ceil);
    return (shares, cost);
  }

  /// @notice ERC7540 - previewRedeem MUST revert for async vaults
  function previewRedeem(
    uint256 shares
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    shares; // silence unused parameter warning
    revert("ERC7540: previewRedeem not supported for async vaults");
  }

  function _previewRedeemWithCost(
    uint256 shares
  ) private view returns (uint256 assets, uint256 cost) {
    assets = _convertToAssets(shares, Math.Rounding.Floor);

    // calculate the amount of assets that will be deutilized
    uint256 assetsToDeutilize = _assetsToDeutilize(assets);

    // apply exit fee to the portion of assets that will be deutilized
    if (assetsToDeutilize > 0) {
      cost = _costOnTotal(assetsToDeutilize, exitCost());
      assets -= cost;
    }

    return (assets, cost);
  }

  /// @notice ERC7540 - maxDeposit returns max assets for requestDeposit
  /// @inheritdoc ERC4626Upgradeable
  function maxDeposit(
    address receiver
  ) public view virtual override(GenesisManagedVault, IERC4626) returns (uint256) {
    if (paused() || isShutdown()) {
      return 0;
    }

    // ERC7540: Return max assets that can be requested for deposit
    // This represents the maximum amount for requestDeposit, not immediate deposit
    uint256 maxCapacity = _calculateMaxDepositRequest(receiver);
    return maxCapacity;
  }

  /// @notice Calculate maximum assets that can be requested for deposit
  function _calculateMaxDepositRequest(address receiver) internal view returns (uint256) {
    uint256 _userDepositLimit = userDepositLimit();
    uint256 _vaultDepositLimit = vaultDepositLimit();

    // If both limits are max, no restriction
    if (_userDepositLimit == type(uint256).max && _vaultDepositLimit == type(uint256).max) {
      return type(uint256).max;
    }

    // Calculate user's current assets (including pending deposits)
    uint256 userShares = balanceOf(receiver);
    uint256 userCurrentAssets = _convertToAssets(userShares, Math.Rounding.Floor);

    // Add any pending deposit assets for this user
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 userPendingAssets = $.pendingDepositAssets[receiver];
    uint256 userTotalAssets = userCurrentAssets + userPendingAssets;

    // Calculate available user limit
    uint256 availableUserLimit = _userDepositLimit > userTotalAssets
      ? _userDepositLimit - userTotalAssets
      : 0;

    // Calculate available vault limit
    uint256 vaultCurrentAssets = totalAssets();
    uint256 availableVaultLimit = _vaultDepositLimit > vaultCurrentAssets
      ? _vaultDepositLimit - vaultCurrentAssets
      : 0;

    // Return the more restrictive limit
    return availableUserLimit < availableVaultLimit ? availableUserLimit : availableVaultLimit;
  }

  /// @notice ERC7540 - maxMint returns 0 since requestMint doesn't exist
  /// @inheritdoc ERC4626Upgradeable
  function maxMint(
    address /* receiver */
  ) public view virtual override(GenesisManagedVault, IERC4626) returns (uint256) {
    // ERC7540: mint() is deprecated and requestMint() doesn't exist
    // Therefore, no shares can be minted directly
    // Users should use requestDeposit() instead
    return 0;
  }

  /// @notice ERC7540 - maxWithdraw returns claimable assets using Pure Pool calculation
  /// @inheritdoc ERC4626Upgradeable
  function maxWithdraw(
    address controller
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Pure Pool: Dynamic calculation of claimable assets
    return _calculateClaimableRedeemAssets(controller);
  }

  /// @notice ERC7540 - maxRedeem returns claimable shares using Pure Pool calculation
  /// @inheritdoc ERC4626Upgradeable
  function maxRedeem(
    address controller
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Pure Pool: Dynamic calculation of claimable shares
    return _calculateClaimableRedeemShares(controller);
  }

  /// @dev If there are pending withdraw requests, the deposited assets is used to process them.
  ///
  /// @inheritdoc ERC4626Upgradeable
  function _deposit(
    address caller,
    address receiver,
    uint256 assets,
    uint256 shares
  ) internal virtual override {
    if (shares == 0) {
      revert ZeroShares();
    }
    super._deposit(caller, receiver, assets, shares);
    // ERC7540: deposit processing is handled separately via processPendingDepositRequests()

    emit VaultState(totalAssets(), totalSupply());
  }

  function _withdraw(
    address caller,
    address receiver,
    address owner,
    uint256 assets,
    uint256 shares
  ) internal virtual override {
    super._withdraw(caller, receiver, owner, assets, shares);

    emit VaultState(totalAssets(), totalSupply());
  }

  /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @dev Calculate available capacity for processing deposit requests
  function _calculateAvailableDepositCapacity() internal view returns (uint256) {
    //  Consider vault deposit limit for processing capacity
    uint256 _vaultDepositLimit = vaultDepositLimit();

    // If vault limit is unlimited, no restriction on processing
    if (_vaultDepositLimit == type(uint256).max) {
      return type(uint256).max;
    }

    // Calculate available vault capacity
    uint256 currentVaultAssets = totalAssets();
    if (currentVaultAssets >= _vaultDepositLimit) {
      return 0; // Vault limit reached, no more processing
    }

    uint256 availableVaultCapacity = _vaultDepositLimit - currentVaultAssets;

    // In the future, this could also be limited by:
    // - Strategy capacity: strategy.getAvailableCapacity()
    // - Daily processing limits
    // - Liquidity constraints
    // For now, only consider vault limit

    return availableVaultCapacity;
  }

  /// @notice Pure Pool-based deposit processing - O(1) complexity
  /// @dev No individual request iteration needed - uses proportional calculation
  function _calculateClaimableDepositAssets(address controller) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    uint256 pendingAssets = $.pendingDepositAssets[controller];
    if (pendingAssets == 0) return 0;

    //  Corrected Pure Pool Calculation
    uint256 totalRequested = $.accRequestedDepositAssets;
    uint256 totalProcessed = $.processedDepositAssets;
    uint256 totalClaimed = $.claimedDepositAssets;

    // Available for claiming = processed - already claimed
    uint256 availableForClaim = totalProcessed - totalClaimed;
    if (availableForClaim == 0) return 0;

    // Total still pending = requested - claimed
    uint256 totalPending = totalRequested - totalClaimed;
    if (totalPending == 0) return 0;

    // Proportional calculation:
    // claimable = (user's pending × available for claim) / total pending
    uint256 claimableAssets = (pendingAssets * availableForClaim) / totalPending;

    return claimableAssets;
  }

  /// @dev Calculate pending redeem amount for a controller
  function _calculatePendingRedeemForController(
    address /* controller */
  ) internal pure returns (uint256) {
    // This is a simplified implementation
    // In a real implementation, you would iterate through all withdraw requests
    // and sum up the pending amounts for this controller
    return 0; // TODO: Implement proper calculation
  }

  /// @dev Calculates the cost that should be added to an amount `assets` that does not include cost.
  /// Used in {IERC4626-mint} and {IERC4626-withdraw} operations.
  function _costOnRaw(uint256 assets, uint256 costRate) private pure returns (uint256) {
    return assets.mulDiv(costRate, FLOAT_PRECISION, Math.Rounding.Ceil);
  }

  /// @dev Calculates the cost part of an amount `assets` that already includes cost.
  /// Used in {IERC4626-deposit} and {IERC4626-redeem} operations.
  function _costOnTotal(uint256 assets, uint256 costRate) private pure returns (uint256) {
    return assets.mulDiv(costRate, costRate + FLOAT_PRECISION, Math.Rounding.Ceil);
  }

  function _assetsToUtilize(uint256 assets) private view returns (uint256) {
    (, uint256 assetsToUtilize) = assets.trySub(totalPendingWithdraw());
    return assetsToUtilize;
  }

  function _assetsToDeutilize(uint256 assets) private view returns (uint256) {
    (, uint256 assetsToDeutilize) = assets.trySub(idleAssets());
    return assetsToDeutilize;
  }

  /*//////////////////////////////////////////////////////////////
                            STORAGE VIEWERS
    //////////////////////////////////////////////////////////////*/

  /// @notice The address of strategy that uses the underlying asset of this vault.
  function strategy() public view returns (address) {
    return GenesisVaultStorage.layout().strategy;
  }

  /// @notice The prioritized accounts.
  /// For example, the addresses of logarithm meta vaults are prioritized to withdraw.
  /// Prioritizing of withdraw means that their withdraw requests are processed before the other normal withdraw requests.
  function prioritizedAccounts() public view returns (address[] memory) {
    return GenesisVaultStorage.layout().prioritizedAccounts;
  }

  /// @notice The entry cost percent that is charged when depositing.
  ///
  /// @dev Denominated in 18 decimals.
  function entryCost() public view returns (uint256) {
    return GenesisVaultStorage.layout().entryCost;
  }

  /// @notice The exit cost percent that is charged when withdrawing.
  ///
  /// @dev Denominated in 18 decimals.
  function exitCost() public view returns (uint256) {
    return GenesisVaultStorage.layout().exitCost;
  }

  /// @notice The address of admin who is responsible for pausing/unpausing vault.
  function admin() public view returns (address) {
    return GenesisVaultStorage.layout().admin;
  }

  /// @notice When this vault is shutdown, only withdrawals are available. It can't be reverted.
  function isShutdown() public view returns (bool) {
    return GenesisVaultStorage.layout().shutdown;
  }
}
