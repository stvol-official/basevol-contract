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

// Interface for BaseVol contract
interface IBaseVol {
  function currentEpoch() external view returns (uint256);
}

contract GenesisVault is GenesisManagedVault, IERC7540 {
  using Math for uint256;
  using SafeERC20 for IERC20;
  using SafeCast for uint256;

  event Shutdown(address account);
  event StrategyUpdated(address account, address newStrategy);
  event VaultState(uint256 indexed totalAssets, uint256 indexed totalSupply);

  // Epoch-based events
  event RoundSettled(uint256 indexed epoch, uint256 sharePrice);

  // Epoch Settlement Processing events
  event RoundSettlementProcessed(
    uint256 indexed epoch,
    uint256 requiredLiquidity,
    uint256 availableLiquidity,
    bool liquidityRequestMade
  );
  event StrategyLiquidityRequested(uint256 amount);
  event StrategyUtilizationNeeded(uint256 idleAssets);

  // Keeper-related events
  event KeeperAdded(address indexed keeper);
  event KeeperRemoved(address indexed keeper);

  // Strategy interaction events
  event StrategyLiquidityRequestFailed(uint256 requestedAmount, string reason);

  // ERC7540 Events (use OpenZeppelin's Withdraw/Redeem events)

  /// @notice Modifier to restrict access to keepers only
  modifier onlyKeeper() {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    bool isKeeper = false;
    for (uint i = 0; i < $.keepers.length; i++) {
      if (msg.sender == $.keepers[i]) {
        isKeeper = true;
        break;
      }
    }
    require(isKeeper, "GenesisVault: caller is not a keeper");
    _;
  }

  function initialize(
    address baseVolContract_,
    address asset_,
    uint256 entryCost_,
    uint256 exitCost_,
    address initialKeeper_,
    string calldata name_,
    string calldata symbol_
  ) external initializer {
    __GenesisManagedVault_init(msg.sender, msg.sender, asset_, name_, symbol_);
    require(initialKeeper_ != address(0), "GenesisVault: invalid initial keeper");

    // Set entry and exit costs using GenesisManagedVault functions
    _setEntryCost(entryCost_);
    _setExitCost(exitCost_);

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    $.baseVolContract = baseVolContract_;

    // Add initial keeper
    $.keepers.push(initialKeeper_);
    emit KeeperAdded(initialKeeper_);
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
                        BASEVOL INTEGRATION FUNCTIONS   
    //////////////////////////////////////////////////////////////*/

  /// @notice Get current epoch from BaseVol system in real-time
  function getCurrentEpoch() public view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    address baseVolContract = $.baseVolContract;

    // If BaseVol contract is not set, fallback to stored epoch
    if (baseVolContract == address(0)) {
      revert BaseVolContractNotSet();
    }

    // Call BaseVol contract to get real-time current epoch
    try IBaseVol(baseVolContract).currentEpoch() returns (uint256 currentEpoch) {
      return currentEpoch;
    } catch {
      revert BaseVolContractNotSet();
    }
  }

  /// @notice Called by BaseVol contract when a round is settled
  /// @param epoch The epoch number that was settled
  function onRoundSettled(uint256 epoch) external onlyKeeper {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

    // Calculate share price based on vault's current state
    uint256 sharePrice = _calculateCurrentSharePrice();

    roundData.sharePrice = sharePrice;
    roundData.isSettled = true;
    roundData.settlementTimestamp = block.timestamp;
    emit RoundSettled(epoch, sharePrice);

    // Process round settlement including liquidity management
    _processRoundSettlement(epoch);

    // Process management fee
    _mintManagementFeeShares();
  }

  /// @notice Set BaseVol contract address (only owner)
  function setBaseVolContract(address _baseVolContract) external onlyOwner {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    $.baseVolContract = _baseVolContract;
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
    require(totalSupply() == 0 && IGenesisStrategy(strategy()).utilizedAssets() == 0);

    // sweep idle assets
    IERC20(asset()).safeTransfer(receiver, idleAssets());
  }

  /*//////////////////////////////////////////////////////////////
                          KEEPER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

  /// @notice Add a keeper address (only admin)
  /// @param keeper The address to add as a keeper
  function addKeeper(address keeper) external onlyAdmin {
    require(keeper != address(0), "GenesisVault: invalid keeper address");

    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Check if keeper already exists
    for (uint i = 0; i < $.keepers.length; i++) {
      require($.keepers[i] != keeper, "GenesisVault: keeper already exists");
    }

    $.keepers.push(keeper);
    emit KeeperAdded(keeper);
  }

  /// @notice Remove a keeper address (only admin)
  /// @param keeper The address to remove from keepers
  function removeKeeper(address keeper) external onlyAdmin {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    for (uint i = 0; i < $.keepers.length; i++) {
      if ($.keepers[i] == keeper) {
        // Move last element to current position and remove last element
        $.keepers[i] = $.keepers[$.keepers.length - 1];
        $.keepers.pop();
        emit KeeperRemoved(keeper);
        return;
      }
    }

    revert("GenesisVault: keeper not found");
  }

  /// @notice Get all keeper addresses
  /// @return Array of keeper addresses
  function getKeepers() external view returns (address[] memory) {
    return GenesisVaultStorage.layout().keepers;
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

    // Apply entry cost - only the net amount after fee goes to investment
    uint256 entryCostAmount = _calculateFixedCost(entryCost());
    uint256 netAssets = assets - entryCostAmount;

    // Transfer entry cost immediately to fee recipient
    _transferFeesToRecipient(entryCostAmount, "entry");

    // Get current epoch from BaseVol system
    uint256 currentEpoch = getCurrentEpoch();

    // ERC7540: Use epoch as requestId for fungibility and simplicity
    requestId = currentEpoch;

    // Update epoch-based tracking with net assets (after fee)
    $.userEpochDepositAssets[controller][currentEpoch] += netAssets;
    $.roundData[currentEpoch].totalRequestedDepositAssets += netAssets;

    // Add to user's epoch list (avoid duplicates)
    if ($.userEpochDepositAssets[controller][currentEpoch] == netAssets) {
      $.userDepositEpochs[controller].push(currentEpoch);

      // Add user to epoch deposit users list for auto-processing (avoid duplicates)
      _addUserToEpochDepositList(controller, currentEpoch);
    }

    emit DepositRequest(controller, owner, requestId, _msgSender(), assets);

    return requestId;
  }

  /// @notice Returns the amount of requested assets in Pending state for the controller with the given requestId to deposit or mint
  /// @param requestId The ID of the request
  /// @param controller The address to check
  /// @return assets The amount of pending deposit assets
  function pendingDepositRequest(
    uint256 requestId,
    address controller
  ) external view override returns (uint256 assets) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any assets in Claimable state for deposit
    // Check if the epoch is settled (i.e., claimable)
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];
    if (roundData.isSettled) {
      return 0; // Assets are in claimable state, not pending
    }

    // Return the pending assets for this controller in this epoch
    return $.userEpochDepositAssets[controller][epoch];
  }

  /// @notice Returns the amount of requested assets in Claimable state for the controller with the given requestId to deposit or mint
  /// @param requestId The ID of the request (epoch number in our implementation)
  /// @param controller The address to check
  /// @return assets The amount of claimable deposit assets
  function claimableDepositRequest(
    uint256 requestId,
    address controller
  ) external view override returns (uint256 assets) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any assets in Pending state for deposit
    // Check if the epoch is settled (i.e., claimable)
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];
    if (!roundData.isSettled) {
      return 0; // Assets are still in pending state, not claimable
    }

    // Calculate claimable assets for this specific epoch
    return _calculateClaimableForEpoch(controller, epoch, true);
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

    // Create request
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // Get current epoch from BaseVol system
    uint256 currentEpoch = getCurrentEpoch();

    // ERC7540: Use epoch as requestId for fungibility and simplicity
    requestId = currentEpoch;

    // Update epoch-based tracking
    $.userEpochRedeemShares[controller][currentEpoch] += shares;
    $.roundData[currentEpoch].totalRequestedRedeemShares += shares;

    // Add to user's epoch list (avoid duplicates)
    if ($.userEpochRedeemShares[controller][currentEpoch] == shares) {
      $.userRedeemEpochs[controller].push(currentEpoch);

      // Add user to epoch redeem users list for auto-processing (avoid duplicates)
      _addUserToEpochRedeemList(controller, currentEpoch);
    }

    emit RedeemRequest(controller, owner, requestId, _msgSender(), shares);

    return requestId;
  }

  /// @notice Returns the amount of requested shares in Pending state for the controller with the given requestId to redeem
  /// @param requestId The ID of the request (epoch number in our implementation)
  /// @param controller The address to check
  /// @return shares The amount of pending redemption shares
  function pendingRedeemRequest(
    uint256 requestId,
    address controller
  ) external view override returns (uint256 shares) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any shares in Claimable state for redeem
    // Check if the epoch is settled (i.e., claimable)
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];
    if (roundData.isSettled) {
      return 0; // Shares are in claimable state, not pending
    }

    // Return the pending shares for this controller in this epoch
    return $.userEpochRedeemShares[controller][epoch];
  }

  /// @notice Returns the amount of requested shares in Claimable state for the controller with the given requestId to redeem
  /// @param requestId The ID of the request (epoch number in our implementation)
  /// @param controller The address to check
  /// @return shares The amount of claimable redemption shares
  function claimableRedeemRequest(
    uint256 requestId,
    address controller
  ) external view override returns (uint256 shares) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();

    // ERC7540: requestId is epoch in our implementation
    uint256 epoch = requestId;

    // MUST NOT include any shares in Pending state for redeem
    // Check if the epoch is settled (i.e., claimable)
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];
    if (!roundData.isSettled) {
      return 0; // Shares are still in pending state, not claimable
    }

    // Calculate claimable shares for this specific epoch
    return _calculateClaimableForEpoch(controller, epoch, false);
  }

  /// @notice The underlying asset amount in this vault that is free to withdraw or utilize.
  /// @dev Excludes pending deposits which are not yet settled
  function idleAssets() public view returns (uint256) {
    uint256 totalBalance = IERC20(asset()).balanceOf(address(this));

    // Subtract total pending deposits (not yet settled)
    uint256 totalPendingDeposits = _totalPendingDeposits();

    // Return total balance minus pending deposits
    (, uint256 settledAssets) = totalBalance.trySub(totalPendingDeposits);

    return settledAssets;
  }

  /// @notice Returns total claimable redeem assets across all settled epochs
  /// @dev This represents assets that users can immediately claim and Strategy needs to prepare for withdrawal
  function totalClaimableWithdraw() public view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalClaimable = 0;

    // Check broader range of epochs with claimable redemptions
    uint256 currentEpoch = getCurrentEpoch();

    // Check last 50 epochs to cover longer settlement periods
    for (uint256 i = 0; i < 50 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      // Only count settled epochs (claimable state)
      if (roundData.isSettled) {
        uint256 requested = roundData.totalRequestedRedeemShares;
        uint256 claimed = roundData.claimedRedeemShares;
        uint256 claimableShares = requested > claimed ? requested - claimed : 0;

        if (claimableShares > 0) {
          // Use epoch-specific share price for accurate calculation
          uint256 claimableAssets = (claimableShares * roundData.sharePrice) / (10 ** decimals());
          totalClaimable += claimableAssets;
        }
      }
    }

    return totalClaimable;
  }

  /*//////////////////////////////////////////////////////////////
                             ERC7540 CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice ERC7540 deposit (claim from async request) - Epoch-based with automatic FIFO processing
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

    // Epoch-based: Calculate total claimable across all epochs
    uint256 totalClaimable = _calculateClaimableDepositAssetsAcrossEpochs(controller);
    require(totalClaimable >= assets, "GenesisVault: insufficient claimable assets");

    // Process claims from oldest to newest epochs (FIFO)
    uint256 remainingAssets = assets;
    uint256 totalShares = 0;

    uint256[] memory userEpochs = $.userDepositEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingAssets > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableAssets = _calculateClaimableForEpoch(controller, epoch, true);
      uint256 assetsToProcess = Math.min(remainingAssets, claimableAssets);

      if (assetsToProcess > 0) {
        // Use epoch-specific share price
        // shares = assets * (10^shareDecimals) / sharePrice
        uint256 epochShares = (assetsToProcess * (10 ** decimals())) / roundData.sharePrice;
        totalShares += epochShares;

        // Update WAEP for the receiver with epoch-specific share price
        _updateUserWAEP(receiver, epochShares, roundData.sharePrice);

        // Update global claimed amount
        roundData.claimedDepositAssets += assetsToProcess;

        // Update user-specific claimed amount
        $.userEpochClaimedDepositAssets[controller][epoch] += assetsToProcess;

        remainingAssets -= assetsToProcess;
      }
    }

    shares = totalShares;
    _mint(receiver, shares);

    emit Deposit(controller, receiver, assets, shares);
    emit VaultState(totalAssets(), totalSupply());
    return shares;
  }

  /// @notice ERC7540 mint (claim from async request) - Epoch-based with automatic FIFO processing
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

    // Process claims from oldest to newest epochs to get the required shares
    uint256 remainingShares = shares;
    uint256 totalAssetsUsed = 0;

    uint256[] memory userEpochs = $.userDepositEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingShares > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableAssets = _calculateClaimableForEpoch(controller, epoch, true);
      if (claimableAssets == 0) continue;

      // Calculate how many shares we can get from this epoch
      uint256 epochShares = (claimableAssets * (10 ** decimals())) / roundData.sharePrice;
      uint256 sharesToProcess = Math.min(remainingShares, epochShares);

      if (sharesToProcess > 0) {
        // Calculate assets needed for these shares using epoch-specific price
        uint256 assetsNeeded = (sharesToProcess * roundData.sharePrice) / (10 ** decimals());
        totalAssetsUsed += assetsNeeded;

        // Update WAEP for the receiver with epoch-specific share price
        _updateUserWAEP(receiver, sharesToProcess, roundData.sharePrice);

        // Update global claimed amount
        roundData.claimedDepositAssets += assetsNeeded;

        // Update user-specific claimed amount
        $.userEpochClaimedDepositAssets[controller][epoch] += assetsNeeded;

        remainingShares -= sharesToProcess;
      }
    }

    require(remainingShares == 0, "GenesisVault: insufficient claimable for shares");

    assets = totalAssetsUsed;
    _mint(receiver, shares);

    emit Deposit(controller, receiver, assets, shares);
    emit VaultState(totalAssets(), totalSupply());
    return assets;
  }

  /// @notice ERC7540 withdraw with Epoch-based calculation
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

    // Calculate gross assets needed to get desired net assets after exit cost
    // For fixed cost: gross = net + fixedCost
    uint256 exitCostAmount = _calculateFixedCost(exitCost());
    uint256 grossAssetsNeeded = assets + exitCostAmount;

    // Epoch-based: Calculate total claimable across all epochs
    uint256 totalClaimable = _calculateClaimableRedeemAssetsAcrossEpochs(controller);
    require(totalClaimable >= grossAssetsNeeded, "GenesisVault: insufficient claimable assets");

    // Process claims from oldest to newest epochs (FIFO)
    uint256 remainingGrossAssets = grossAssetsNeeded;
    uint256 totalShares = 0;
    uint256 totalPerformanceFees = 0;

    uint256[] memory userEpochs = $.userRedeemEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingGrossAssets > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableShares = _calculateClaimableForEpoch(controller, epoch, false);
      if (claimableShares == 0) continue;

      // Calculate assets available from this epoch
      uint256 epochAssets = (claimableShares * roundData.sharePrice) / (10 ** decimals());
      uint256 assetsToProcess = Math.min(remainingGrossAssets, epochAssets);

      if (assetsToProcess > 0) {
        // Calculate shares needed using epoch-specific share price
        uint256 epochSharesNeeded = (assetsToProcess * (10 ** decimals())) / roundData.sharePrice;
        totalShares += epochSharesNeeded;

        // Calculate and charge performance fee for this withdrawal
        uint256 feeAmount = _calculateAndChargePerformanceFee(
          controller,
          epochSharesNeeded,
          roundData.sharePrice
        );
        totalPerformanceFees += feeAmount;

        // Update global claimed amount
        roundData.claimedRedeemShares += epochSharesNeeded;

        // Update user-specific claimed amount
        $.userEpochClaimedRedeemShares[controller][epoch] += epochSharesNeeded;

        remainingGrossAssets -= assetsToProcess;
      }
    }

    shares = totalShares;

    // Apply exit cost to gross assets
    _transferFeesToRecipient(exitCostAmount, "exit");

    // Final amount = gross assets - exit cost - performance fees
    uint256 finalAmount = grossAssetsNeeded - exitCostAmount - totalPerformanceFees;
    require(finalAmount >= assets, "GenesisVault: insufficient after fees");

    IERC20(asset()).safeTransfer(receiver, assets);

    emit Withdraw(_msgSender(), receiver, controller, assets, shares);
    return shares;
  }

  /// @notice ERC7540 redeem with Epoch-based calculation
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

    // Epoch-based: Calculate total claimable across all epochs
    uint256 totalClaimable = _calculateClaimableRedeemSharesAcrossEpochs(controller);
    require(totalClaimable >= shares, "GenesisVault: insufficient claimable shares");

    // Process claims from oldest to newest epochs (FIFO)
    uint256 remainingShares = shares;
    uint256 totalAssetsRedeemed = 0;
    uint256 totalPerformanceFees = 0;

    uint256[] memory userEpochs = $.userRedeemEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingShares > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableShares = _calculateClaimableForEpoch(controller, epoch, false);
      uint256 sharesToProcess = Math.min(remainingShares, claimableShares);

      if (sharesToProcess > 0) {
        // Use epoch-specific share price
        uint256 epochAssets = (sharesToProcess * roundData.sharePrice) / (10 ** decimals());
        totalAssetsRedeemed += epochAssets;

        // Calculate and charge performance fee for this redemption
        uint256 feeAmount = _calculateAndChargePerformanceFee(
          controller,
          sharesToProcess,
          roundData.sharePrice
        );
        totalPerformanceFees += feeAmount;

        // Update global claimed amount
        roundData.claimedRedeemShares += sharesToProcess;

        // Update user-specific claimed amount
        $.userEpochClaimedRedeemShares[controller][epoch] += sharesToProcess;

        remainingShares -= sharesToProcess;
      }
    }

    // Apply exit cost - user receives net amount after fee deduction
    uint256 exitCostAmount = _calculateFixedCost(exitCost());
    assets = totalAssetsRedeemed - exitCostAmount - totalPerformanceFees;

    // Transfer exit cost immediately to fee recipient
    _transferFeesToRecipient(exitCostAmount, "exit");

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
    // Only subtract confirmed obligations (claimable), not pending (unconfirmed) obligations
    // Pending withdraws use current share price which is inaccurate for unsettled epochs
    (, assets) = (idleAssets() + IGenesisStrategy(strategy()).totalAssetsUnderManagement()).trySub(
      totalClaimableWithdraw()
    );
    return assets;
  }

  /// @notice ERC7540 - previewDeposit MUST revert for async vaults
  /// @inheritdoc ERC4626Upgradeable
  function previewDeposit(
    uint256 assets
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    assets; // silence unused parameter warning
    revert("ERC7540: previewDeposit not supported for async vaults");
  }

  /// @notice ERC7540 - previewMint MUST revert for async vaults
  /// @inheritdoc ERC4626Upgradeable
  function previewMint(
    uint256 shares
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    shares; // silence unused parameter warning
    revert("ERC7540: previewMint not supported for async vaults");
  }

  /// @notice ERC7540 - previewWithdraw MUST revert for async vaults
  function previewWithdraw(
    uint256 assets
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    assets; // silence unused parameter warning
    revert("ERC7540: previewWithdraw not supported for async vaults");
  }

  /// @notice ERC7540 - previewRedeem MUST revert for async vaults
  function previewRedeem(
    uint256 shares
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    shares; // silence unused parameter warning
    revert("ERC7540: previewRedeem not supported for async vaults");
  }

  /// @notice ERC7540 - maxDeposit returns max assets for deposit (claimable)
  /// @inheritdoc ERC4626Upgradeable
  function maxDeposit(
    address receiver
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (paused() || isShutdown()) {
      return 0;
    }

    // Return max assets that can be claimed via deposit() function
    // This represents claimable deposit assets across all settled epochs
    return _calculateClaimableDepositAssetsAcrossEpochs(receiver);
  }

  /// @notice Calculate maximum assets that can be requested for deposit
  function _calculateMaxDepositRequest(address receiver) internal view returns (uint256) {
    // TODO: Adjust this to use epoch-based data

    uint256 _userDepositLimit = userDepositLimit();
    uint256 _vaultDepositLimit = vaultDepositLimit();

    // If both limits are max, no restriction
    if (_userDepositLimit == type(uint256).max && _vaultDepositLimit == type(uint256).max) {
      return type(uint256).max;
    }

    // Calculate user's current assets (including pending deposits)
    uint256 userShares = balanceOf(receiver);
    uint256 userCurrentAssets = convertToAssets(userShares);

    // Add any pending deposit assets for this user (across all unsettled epochs)
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 userPendingAssets = 0;
    uint256[] memory userEpochs = $.userDepositEpochs[receiver];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];
      if (!$.roundData[epoch].isSettled) {
        userPendingAssets += $.userEpochDepositAssets[receiver][epoch];
      }
    }

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

  /// @notice ERC7540 - maxMint returns max shares for mint (claimable)
  /// @inheritdoc ERC4626Upgradeable
  function maxMint(
    address receiver
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (paused() || isShutdown()) {
      return 0;
    }

    // Return max shares that can be claimed via mint() function
    // Calculate based on claimable deposit assets across all settled epochs
    uint256 claimableAssets = _calculateClaimableDepositAssetsAcrossEpochs(receiver);
    if (claimableAssets == 0) {
      return 0;
    }

    // Convert claimable assets to shares using epoch-specific calculations
    return _calculateClaimableSharesFromAssets(receiver, claimableAssets);
  }

  /// @notice Returns the maximum amount of assets that can be requested for deposit
  /// @param receiver The address that will receive the shares after settlement
  /// @return assets The maximum amount of assets that can be requested via requestDeposit
  function maxRequestDeposit(address receiver) public view returns (uint256) {
    if (paused() || isShutdown()) {
      return 0;
    }

    // Return max assets that can be requested for deposit
    // This represents the maximum amount for requestDeposit based on deposit limits
    return _calculateMaxDepositRequest(receiver);
  }

  /// @notice Returns the maximum amount of shares that can be requested for redeem
  /// @param owner The address that owns the shares to be redeemed
  /// @return shares The maximum amount of shares that can be requested via requestRedeem
  function maxRequestRedeem(address owner) public view returns (uint256) {
    if (paused() || isShutdown()) {
      return 0;
    }

    // Return max shares that can be requested for redeem
    // This is simply the owner's current share balance since they can request to redeem all their shares
    return balanceOf(owner);
  }

  /// @notice ERC7540 - maxWithdraw returns claimable assets using Epoch-based calculation
  /// @inheritdoc ERC4626Upgradeable
  function maxWithdraw(
    address controller
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Epoch-based: Dynamic calculation of claimable assets across all epochs
    return _calculateClaimableRedeemAssetsAcrossEpochs(controller);
  }

  /// @notice ERC7540 - maxRedeem returns claimable shares using Epoch-based calculation
  /// @inheritdoc ERC4626Upgradeable
  function maxRedeem(
    address controller
  ) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
    if (paused()) {
      return 0;
    }
    // Epoch-based: Dynamic calculation of claimable shares across all epochs
    return _calculateClaimableRedeemSharesAcrossEpochs(controller);
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
                        EPOCH-BASED HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Calculate claimable assets/shares for a specific epoch
  /// @param controller The controller address
  /// @param epoch The epoch to check
  /// @param isDeposit True for deposit assets, false for redeem shares
  /// @return claimable The amount claimable for this epoch
  function _calculateClaimableForEpoch(
    address controller,
    uint256 epoch,
    bool isDeposit
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

    if (!roundData.isSettled) return 0;

    if (isDeposit) {
      uint256 userTotal = $.userEpochDepositAssets[controller][epoch];
      uint256 userClaimed = $.userEpochClaimedDepositAssets[controller][epoch];

      if (userTotal == 0) return 0;

      // Simple and accurate: total - claimed = claimable
      return userTotal > userClaimed ? userTotal - userClaimed : 0;
    } else {
      uint256 userTotal = $.userEpochRedeemShares[controller][epoch];
      uint256 userClaimed = $.userEpochClaimedRedeemShares[controller][epoch];

      if (userTotal == 0) return 0;

      // Simple and accurate: total - claimed = claimable
      return userTotal > userClaimed ? userTotal - userClaimed : 0;
    }
  }

  /// @notice Calculate claimable deposit assets across all settled epochs
  function _calculateClaimableDepositAssetsAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalClaimable = 0;
    uint256[] memory userEpochs = $.userDepositEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (roundData.isSettled) {
        totalClaimable += _calculateClaimableForEpoch(controller, epoch, true);
      }
    }
    return totalClaimable;
  }

  /// @notice Calculate claimable redeem shares across all settled epochs
  function _calculateClaimableRedeemSharesAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalClaimable = 0;
    uint256[] memory userEpochs = $.userRedeemEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (roundData.isSettled) {
        totalClaimable += _calculateClaimableForEpoch(controller, epoch, false);
      }
    }
    return totalClaimable;
  }

  /// @notice Calculate maximum shares that can be obtained from claimable assets
  /// @param controller The controller address
  /// @param claimableAssets The total claimable assets amount
  /// @return shares The maximum shares that can be minted from claimable assets
  function _calculateClaimableSharesFromAssets(
    address controller,
    uint256 claimableAssets
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalShares = 0;
    uint256 remainingAssets = claimableAssets;

    uint256[] memory userEpochs = $.userDepositEpochs[controller];
    for (uint256 i = 0; i < userEpochs.length && remainingAssets > 0; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (!roundData.isSettled) continue;

      uint256 claimableAssetsForEpoch = _calculateClaimableForEpoch(controller, epoch, true);
      uint256 assetsToProcess = Math.min(remainingAssets, claimableAssetsForEpoch);

      if (assetsToProcess > 0) {
        // Use epoch-specific share price to calculate shares
        // shares = assets * (10^shareDecimals) / sharePrice
        uint256 epochShares = (assetsToProcess * (10 ** decimals())) / roundData.sharePrice;
        totalShares += epochShares;
        remainingAssets -= assetsToProcess;
      }
    }

    return totalShares;
  }

  /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Calculate share price for a current epoch based on vault performance
  /// @return sharePrice The calculated share price (assets per share scaled by share decimals)
  function _calculateCurrentSharePrice() internal view returns (uint256) {
    // If this is the first epoch or vault has no shares, use initial price
    if (totalSupply() == 0) {
      // Return 1 share worth 1 asset unit, scaled properly for decimals
      return 10 ** decimals(); // This handles the decimals offset correctly
    }

    // Get strategy performance data for this epoch
    address strategyAddress = strategy();
    if (strategyAddress == address(0)) {
      // No strategy deployed yet, return 1:1 ratio
      return 10 ** decimals();
    }

    // Calculate share price based on total vault value EXCLUDING pending deposits
    // This prevents pending deposits from inflating the share price before epoch settlement
    uint256 vaultTotalAssets = _totalAssetsForSharePrice();

    // Include pending redeem shares in total supply for consistent share price calculation
    // This mirrors how we exclude pending deposits from assets
    uint256 vaultTotalSupply = totalSupply() + _totalPendingRedeemShares();

    if (vaultTotalSupply == 0) {
      return 10 ** decimals();
    }

    // Share price = (total assets per share) scaled by share decimals
    // For proper decimals handling: assets * 10^shareDecimals / totalSupply
    return (vaultTotalAssets * (10 ** decimals())) / vaultTotalSupply;
  }

  /// @notice Calculate total assets for share price calculation (excluding pending deposits)
  /// @dev This prevents pending deposits from artificially inflating share price before settlement
  /// @return assets Total assets excluding pending deposits
  function _totalAssetsForSharePrice() internal view returns (uint256) {
    // Start with current strategy-controlled assets and claimable obligations
    address strategyAddress = strategy();
    uint256 strategyAssets = strategyAddress != address(0)
      ? IGenesisStrategy(strategyAddress).totalAssetsUnderManagement()
      : 0;

    // Add only settled (non-pending) idle assets
    uint256 settledIdleAssets = idleAssets();

    // Subtract claimable withdrawals
    uint256 claimableWithdrawals = totalClaimableWithdraw();

    (, uint256 totalAssetsForPrice) = (settledIdleAssets + strategyAssets).trySub(
      claimableWithdrawals
    );
    return totalAssetsForPrice;
  }

  /// @notice Calculate total pending deposit assets across all unsettled epochs
  /// @return pendingAssets Total assets in pending state
  function _totalPendingDeposits() internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalPending = 0;
    uint256 currentEpoch = getCurrentEpoch();

    // Check recent epochs (last 10) for pending deposits
    for (uint256 i = 0; i < 10 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (!roundData.isSettled && roundData.totalRequestedDepositAssets > 0) {
        totalPending += roundData.totalRequestedDepositAssets;
      }
    }

    return totalPending;
  }

  /// @notice Calculate total pending redeem shares across all unsettled epochs
  /// @return pendingShares Total shares in pending state
  function _totalPendingRedeemShares() internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalPending = 0;
    uint256 currentEpoch = getCurrentEpoch();

    // Check recent epochs (last 10) for pending redeems
    for (uint256 i = 0; i < 10 && currentEpoch >= i; i++) {
      uint256 epoch = currentEpoch - i;
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (!roundData.isSettled && roundData.totalRequestedRedeemShares > 0) {
        totalPending += roundData.totalRequestedRedeemShares;
      }
    }

    return totalPending;
  }

  /// @notice Calculate claimable redeem assets across all settled epochs (for legacy functions)
  function _calculateClaimableRedeemAssetsAcrossEpochs(
    address controller
  ) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    uint256 totalClaimable = 0;
    uint256[] memory userEpochs = $.userRedeemEpochs[controller];

    for (uint256 i = 0; i < userEpochs.length; i++) {
      uint256 epoch = userEpochs[i];
      GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

      if (roundData.isSettled) {
        uint256 claimableShares = _calculateClaimableForEpoch(controller, epoch, false);
        // Convert shares to assets using epoch-specific share price
        totalClaimable += (claimableShares * roundData.sharePrice) / (10 ** decimals());
      }
    }
    return totalClaimable;
  }

  /*//////////////////////////////////////////////////////////////
                    ROUND SETTLEMENT PROCESSING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Calculate required assets for redemptions in a specific round (excluding fees)
  /// @param epoch The round id (=epoch) to calculate redeem assets for
  /// @return Total assets needed for redemptions in this round
  function _calculateRoundRedeemAssets(uint256 epoch) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

    if (!roundData.isSettled) return 0;

    uint256 totalRedeemShares = roundData.totalRequestedRedeemShares;
    uint256 claimedShares = roundData.claimedRedeemShares;
    uint256 claimableShares = totalRedeemShares > claimedShares
      ? totalRedeemShares - claimedShares
      : 0;

    if (claimableShares == 0) return 0;

    // Use round-specific share price for accurate asset calculation
    return (claimableShares * roundData.sharePrice) / (10 ** decimals());
  }

  /// @notice Calculate deposit assets ready for processing in a specific epoch
  /// @param epoch The round id (=epoch) to calculate deposit assets for
  /// @return Total assets ready for deposit processing in this epoch
  function _calculateRoundDepositAssets(uint256 epoch) internal view returns (uint256) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

    if (!roundData.isSettled) return 0;

    uint256 totalDepositAssets = roundData.totalRequestedDepositAssets;
    uint256 claimedAssets = roundData.claimedDepositAssets;

    return totalDepositAssets > claimedAssets ? totalDepositAssets - claimedAssets : 0;
  }

  /// @notice Process epoch settlement including liquidity management and strategy coordination
  /// @param epoch The settled round id (=epoch)
  function _processRoundSettlement(uint256 epoch) internal {
    // 1. Calculate required assets for redemptions in this epoch
    uint256 requiredRedeemAssets = _calculateRoundRedeemAssets(epoch);

    // 2. Check current available assets
    uint256 availableAssets = idleAssets();

    // 3. Request liquidity from strategy if insufficient
    bool liquidityRequestMade = false;
    if (requiredRedeemAssets > availableAssets) {
      uint256 shortfall = requiredRedeemAssets - availableAssets;
      _requestLiquidityFromStrategy(shortfall);
      liquidityRequestMade = true;
    }

    // 4. Auto-process all user requests for this epoch
    _autoProcessEpochRequests(epoch);

    // 5. Signal strategy for idle asset utilization (async)
    _notifyStrategyForUtilization();

    emit RoundSettlementProcessed(
      epoch,
      requiredRedeemAssets,
      availableAssets,
      liquidityRequestMade
    );
  }

  /// @notice Request liquidity from strategy to meet withdrawal demands
  /// @param amount Required liquidity amount
  function _requestLiquidityFromStrategy(uint256 amount) internal {
    address strategyAddr = strategy();
    if (strategyAddr == address(0)) {
      emit StrategyLiquidityRequestFailed(amount, "Strategy not set");
      return;
    }

    // Request specific amount of liquidity from strategy
    // Strategy will intelligently source from: 1) idle assets, 2) BaseVol, 3) Morpho
    try IGenesisStrategy(strategyAddr).provideLiquidityForWithdrawals(amount) {
      emit StrategyLiquidityRequested(amount);
    } catch Error(string memory reason) {
      // Strategy call failure should not stop vault settlement
      // Fallback to basic asset processing
      try IGenesisStrategy(strategyAddr).processAssetsToWithdraw() {
        emit StrategyLiquidityRequested(amount);
        emit StrategyLiquidityRequestFailed(
          amount,
          string(abi.encodePacked("Primary method failed: ", reason, " - Used fallback"))
        );
      } catch Error(string memory fallbackReason) {
        // Both methods failed - log the failures and continue
        emit StrategyLiquidityRequestFailed(
          amount,
          string(
            abi.encodePacked(
              "Both methods failed - Primary: ",
              reason,
              " Fallback: ",
              fallbackReason
            )
          )
        );
      } catch {
        // Fallback method failed with unknown error
        emit StrategyLiquidityRequestFailed(
          amount,
          string(abi.encodePacked("Primary failed: ", reason, " - Fallback failed: Unknown error"))
        );
      }
    } catch {
      // Primary method failed with unknown error - try fallback
      try IGenesisStrategy(strategyAddr).processAssetsToWithdraw() {
        emit StrategyLiquidityRequested(amount);
        emit StrategyLiquidityRequestFailed(
          amount,
          "Primary method failed: Unknown error - Used fallback"
        );
      } catch Error(string memory fallbackReason) {
        emit StrategyLiquidityRequestFailed(
          amount,
          string(
            abi.encodePacked(
              "Both methods failed - Primary: Unknown error, Fallback: ",
              fallbackReason
            )
          )
        );
      } catch {
        emit StrategyLiquidityRequestFailed(amount, "Both methods failed with unknown errors");
      }
    }
  }

  /// @notice Auto-process all user requests for the given epoch
  /// @param epoch The epoch to process user requests for
  function _autoProcessEpochRequests(uint256 epoch) internal {
    // Process all redemption requests first (withdraw assets from vault)
    _autoProcessEpochRedeems(epoch);

    // Process all deposit requests second (mint shares to users)
    _autoProcessEpochDeposits(epoch);
  }

  /// @notice Auto-process all redemption requests for the given epoch
  /// @param epoch The epoch to process redemption requests for
  function _autoProcessEpochRedeems(uint256 epoch) internal {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    address[] memory redeemUsers = $.epochRedeemUsers[epoch];

    for (uint256 i = 0; i < redeemUsers.length; i++) {
      address user = redeemUsers[i];
      _autoProcessUserRedeem(user, epoch);
    }
  }

  /// @notice Auto-process all deposit requests for the given epoch
  /// @param epoch The epoch to process deposit requests for
  function _autoProcessEpochDeposits(uint256 epoch) internal {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    address[] memory depositUsers = $.epochDepositUsers[epoch];

    for (uint256 i = 0; i < depositUsers.length; i++) {
      address user = depositUsers[i];
      _autoProcessUserDeposit(user, epoch);
    }
  }

  /// @notice Auto-process a single user's redemption requests for the given epoch
  /// @param user The user address to process
  /// @param epoch The epoch to process
  function _autoProcessUserRedeem(address user, uint256 epoch) internal {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

    if (!roundData.isSettled) return;

    // Calculate user's claimable shares for this epoch
    uint256 claimableShares = _calculateClaimableForEpoch(user, epoch, false);
    if (claimableShares == 0) return;

    // Calculate assets to transfer using epoch-specific share price
    uint256 grossAssets = (claimableShares * roundData.sharePrice) / (10 ** decimals());

    // Calculate and charge performance fee for this redemption
    uint256 performanceFeeAmount = _calculateAndChargePerformanceFee(
      user,
      claimableShares,
      roundData.sharePrice
    );

    // Apply exit cost - user receives net amount after fee deduction
    uint256 exitCostAmount = _calculateFixedCost(exitCost());
    uint256 netAssets = grossAssets - exitCostAmount - performanceFeeAmount;

    // Transfer exit cost immediately to fee recipient
    _transferFeesToRecipient(exitCostAmount, "exit");

    // Update claimed amounts
    roundData.claimedRedeemShares += claimableShares;
    $.userEpochClaimedRedeemShares[user][epoch] += claimableShares;

    // Transfer assets to user (controller = receiver in auto-processing)
    IERC20(asset()).safeTransfer(user, netAssets);

    // Emit withdrawal event
    emit Withdraw(address(this), user, user, netAssets, claimableShares);
  }

  /// @notice Auto-process a single user's deposit requests for the given epoch
  /// @param user The user address to process
  /// @param epoch The epoch to process
  function _autoProcessUserDeposit(address user, uint256 epoch) internal {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    GenesisVaultStorage.RoundData storage roundData = $.roundData[epoch];

    if (!roundData.isSettled) return;

    // Calculate user's claimable assets for this epoch
    uint256 claimableAssets = _calculateClaimableForEpoch(user, epoch, true);
    if (claimableAssets == 0) return;

    // Calculate shares to mint using epoch-specific share price
    uint256 sharesToMint = (claimableAssets * (10 ** decimals())) / roundData.sharePrice;

    // Update WAEP for the user with epoch-specific share price
    _updateUserWAEP(user, sharesToMint, roundData.sharePrice);

    // Update claimed amounts
    roundData.claimedDepositAssets += claimableAssets;
    $.userEpochClaimedDepositAssets[user][epoch] += claimableAssets;

    // Mint shares to user (controller = receiver in auto-processing)
    _mint(user, sharesToMint);

    // Emit deposit event
    emit Deposit(user, user, claimableAssets, sharesToMint);
  }

  /// @notice Signal strategy about idle asset utilization opportunity
  function _notifyStrategyForUtilization() internal {
    // Strategy's keeperRebalance is only callable by operator
    // Emit event for keeper to detect and trigger rebalancing
    emit StrategyUtilizationNeeded(idleAssets());
  }

  /*//////////////////////////////////////////////////////////////
                    AUTO-PROCESSING HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

  /// @notice Add user to epoch deposit users list (avoiding duplicates)
  /// @param user The user address to add
  /// @param epoch The epoch to add the user to
  function _addUserToEpochDepositList(address user, uint256 epoch) internal {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    address[] storage epochUsers = $.epochDepositUsers[epoch];

    // Check if user already exists in the list to avoid duplicates
    for (uint256 i = 0; i < epochUsers.length; i++) {
      if (epochUsers[i] == user) {
        return; // User already exists, no need to add
      }
    }

    // Add user to the list
    epochUsers.push(user);
  }

  /// @notice Add user to epoch redeem users list (avoiding duplicates)
  /// @param user The user address to add
  /// @param epoch The epoch to add the user to
  function _addUserToEpochRedeemList(address user, uint256 epoch) internal {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    address[] storage epochUsers = $.epochRedeemUsers[epoch];

    // Check if user already exists in the list to avoid duplicates
    for (uint256 i = 0; i < epochUsers.length; i++) {
      if (epochUsers[i] == user) {
        return; // User already exists, no need to add
      }
    }

    // Add user to the list
    epochUsers.push(user);
  }

  /// @notice Get list of users who made deposit requests in an epoch
  /// @param epoch The epoch to query
  /// @return users Array of user addresses
  function getEpochDepositUsers(uint256 epoch) external view returns (address[] memory) {
    return GenesisVaultStorage.layout().epochDepositUsers[epoch];
  }

  /// @notice Get list of users who made redeem requests in an epoch
  /// @param epoch The epoch to query
  /// @return users Array of user addresses
  function getEpochRedeemUsers(uint256 epoch) external view returns (address[] memory) {
    return GenesisVaultStorage.layout().epochRedeemUsers[epoch];
  }

  /*//////////////////////////////////////////////////////////////
                            STORAGE VIEWERS
    //////////////////////////////////////////////////////////////*/

  /// @notice The address of strategy that uses the underlying asset of this vault.
  function strategy() public view returns (address) {
    return GenesisVaultStorage.layout().strategy;
  }

  /// @notice When this vault is shutdown, only withdrawals are available. It can't be reverted.
  function isShutdown() public view returns (bool) {
    return GenesisVaultStorage.layout().shutdown;
  }

  /// @notice The address of baseVol contract.
  function baseVolContract() public view returns (address) {
    return GenesisVaultStorage.layout().baseVolContract;
  }

  function roundData(uint256 epoch) public view returns (GenesisVaultStorage.RoundData memory) {
    GenesisVaultStorage.Layout storage $ = GenesisVaultStorage.layout();
    return $.roundData[epoch];
  }
}
