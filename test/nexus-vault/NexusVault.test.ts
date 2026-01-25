import { ethers } from "hardhat";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

/**
 * NexusVault Diamond Test Suite
 *
 * Tests cover:
 * - Diamond deployment and initialization
 * - ERC20 functionality
 * - ERC4626 vault operations (deposit, withdraw, mint, redeem)
 * - Multi-vault management
 * - Rebalancing
 * - Fee collection
 * - Access control
 * - Emergency operations
 */

describe("NexusVault", function () {
  // Fixture to deploy the complete NexusVault Diamond
  async function deployNexusVaultFixture() {
    const [owner, admin, keeper, user1, user2, feeRecipient] = await ethers.getSigners();

    // Deploy Mock USDC
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20.deploy("USD Coin", "USDC", 6);
    await usdc.waitForDeployment();

    // Deploy Mock ERC4626 Vaults
    const MockVault1 = await ethers.getContractFactory("MockERC4626");
    const vault1 = await MockVault1.deploy(await usdc.getAddress(), "Vault 1", "V1");
    await vault1.waitForDeployment();

    const MockVault2 = await ethers.getContractFactory("MockERC4626");
    const vault2 = await MockVault2.deploy(await usdc.getAddress(), "Vault 2", "V2");
    await vault2.waitForDeployment();

    // Deploy Facets
    const DiamondCutFacet = await ethers.getContractFactory(
      "contracts/diamond-common/facets/DiamondCutFacet.sol:DiamondCutFacet"
    );
    const diamondCutFacet = await DiamondCutFacet.deploy();

    const DiamondLoupeFacet = await ethers.getContractFactory(
      "contracts/diamond-common/facets/DiamondLoupeFacet.sol:DiamondLoupeFacet"
    );
    const diamondLoupeFacet = await DiamondLoupeFacet.deploy();

    const ERC20Facet = await ethers.getContractFactory(
      "contracts/nexus-vault/facets/ERC20Facet.sol:ERC20Facet"
    );
    const erc20Facet = await ERC20Facet.deploy();

    const NexusVaultViewFacet = await ethers.getContractFactory(
      "contracts/nexus-vault/facets/NexusVaultViewFacet.sol:NexusVaultViewFacet"
    );
    const viewFacet = await NexusVaultViewFacet.deploy();

    const NexusVaultAdminFacet = await ethers.getContractFactory(
      "contracts/nexus-vault/facets/NexusVaultAdminFacet.sol:NexusVaultAdminFacet"
    );
    const adminFacet = await NexusVaultAdminFacet.deploy();

    const NexusVaultCoreFacet = await ethers.getContractFactory(
      "contracts/nexus-vault/facets/NexusVaultCoreFacet.sol:NexusVaultCoreFacet"
    );
    const coreFacet = await NexusVaultCoreFacet.deploy();

    const NexusVaultRebalanceFacet = await ethers.getContractFactory(
      "contracts/nexus-vault/facets/NexusVaultRebalanceFacet.sol:NexusVaultRebalanceFacet"
    );
    const rebalanceFacet = await NexusVaultRebalanceFacet.deploy();

    const NexusVaultInitFacet = await ethers.getContractFactory(
      "contracts/nexus-vault/facets/NexusVaultInitFacet.sol:NexusVaultInitFacet"
    );
    const initFacet = await NexusVaultInitFacet.deploy();

    // Helper to get selectors
    const getSelectors = (contract: any, exclude: string[] = []) => {
      const fragments = Object.values(contract.interface.fragments) as any[];
      return fragments
        .filter((f) => f.type === "function")
        .map((f) => f.selector)
        .filter((s: string) => s !== undefined && !exclude.includes(s));
    };

    // Prepare initial cuts
    const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };
    const initialCuts = [
      {
        facetAddress: await diamondCutFacet.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(diamondCutFacet),
      },
    ];

    // Deploy Diamond
    const NexusVaultDiamond = await ethers.getContractFactory(
      "contracts/nexus-vault/NexusVaultDiamond.sol:NexusVaultDiamond"
    );
    const diamond = await NexusVaultDiamond.deploy(owner.address, initialCuts);
    await diamond.waitForDeployment();
    const diamondAddress = await diamond.getAddress();

    // Add remaining facets
    const diamondCut = await ethers.getContractAt(
      "contracts/diamond-common/interfaces/IDiamondCut.sol:IDiamondCut",
      diamondAddress
    );

    const cuts = [
      {
        facetAddress: await diamondLoupeFacet.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(diamondLoupeFacet),
      },
      {
        facetAddress: await erc20Facet.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(erc20Facet),
      },
      {
        facetAddress: await viewFacet.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(viewFacet, [
          "0x06fdde03", // name
          "0x95d89b41", // symbol
          "0x313ce567", // decimals
          "0x18160ddd", // totalSupply
        ]),
      },
      {
        facetAddress: await adminFacet.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(adminFacet),
      },
      {
        facetAddress: await coreFacet.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(coreFacet),
      },
      {
        facetAddress: await rebalanceFacet.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(rebalanceFacet),
      },
      {
        facetAddress: await initFacet.getAddress(),
        action: FacetCutAction.Add,
        functionSelectors: getSelectors(initFacet),
      },
    ];

    await diamondCut.diamondCut(cuts, ethers.ZeroAddress, "0x");

    // Initialize vault
    const nexusInit = await ethers.getContractAt(
      "contracts/nexus-vault/facets/NexusVaultInitFacet.sol:NexusVaultInitFacet",
      diamondAddress
    );
    await nexusInit.initialize(
      await usdc.getAddress(),
      "Nexus Vault",
      "nxVAULT",
      admin.address,
      feeRecipient.address
    );

    // Get contract interfaces
    const nexusVault = {
      erc20: await ethers.getContractAt(
        "contracts/nexus-vault/facets/ERC20Facet.sol:ERC20Facet",
        diamondAddress
      ),
      view: await ethers.getContractAt(
        "contracts/nexus-vault/facets/NexusVaultViewFacet.sol:NexusVaultViewFacet",
        diamondAddress
      ),
      admin: await ethers.getContractAt(
        "contracts/nexus-vault/facets/NexusVaultAdminFacet.sol:NexusVaultAdminFacet",
        diamondAddress
      ),
      core: await ethers.getContractAt(
        "contracts/nexus-vault/facets/NexusVaultCoreFacet.sol:NexusVaultCoreFacet",
        diamondAddress
      ),
      rebalance: await ethers.getContractAt(
        "contracts/nexus-vault/facets/NexusVaultRebalanceFacet.sol:NexusVaultRebalanceFacet",
        diamondAddress
      ),
    };

    // Mint USDC to users
    const mintAmount = ethers.parseUnits("100000", 6);
    await usdc.mint(user1.address, mintAmount);
    await usdc.mint(user2.address, mintAmount);

    return {
      diamond,
      diamondAddress,
      nexusVault,
      usdc,
      vault1,
      vault2,
      owner,
      admin,
      keeper,
      user1,
      user2,
      feeRecipient,
    };
  }

  describe("Deployment & Initialization", function () {
    it("should deploy with correct name and symbol", async function () {
      const { nexusVault } = await loadFixture(deployNexusVaultFixture);

      expect(await nexusVault.erc20.name()).to.equal("Nexus Vault");
      expect(await nexusVault.erc20.symbol()).to.equal("nxVAULT");
    });

    it("should set correct owner and admin", async function () {
      const { nexusVault, owner, admin } = await loadFixture(deployNexusVaultFixture);

      expect(await nexusVault.view.owner()).to.equal(owner.address);
      expect(await nexusVault.view.admin()).to.equal(admin.address);
    });

    it("should set correct asset", async function () {
      const { nexusVault, usdc } = await loadFixture(deployNexusVaultFixture);

      expect(await nexusVault.view.asset()).to.equal(await usdc.getAddress());
    });

    it("should not be paused initially", async function () {
      const { nexusVault } = await loadFixture(deployNexusVaultFixture);

      expect(await nexusVault.view.paused()).to.equal(false);
    });

    it("should revert on double initialization", async function () {
      const { diamondAddress, usdc, admin, feeRecipient } = await loadFixture(
        deployNexusVaultFixture
      );

      const nexusInit = await ethers.getContractAt(
        "contracts/nexus-vault/facets/NexusVaultInitFacet.sol:NexusVaultInitFacet",
        diamondAddress
      );

      await expect(
        nexusInit.initialize(
          await usdc.getAddress(),
          "Test",
          "TEST",
          admin.address,
          feeRecipient.address
        )
      ).to.be.revertedWithCustomError(nexusInit, "AlreadyInitialized");
    });
  });

  describe("Vault Management", function () {
    it("should add vault with correct weights", async function () {
      const { nexusVault, vault1, admin } = await loadFixture(deployNexusVaultFixture);

      const targetWeight = ethers.parseEther("0.5"); // 50%
      const maxWeight = ethers.parseEther("0.7"); // 70%
      const minWeight = ethers.parseEther("0.3"); // 30%

      await nexusVault.admin
        .connect(admin)
        .addVault(await vault1.getAddress(), targetWeight, maxWeight, minWeight);

      const config = await nexusVault.view.getVaultConfigFull(await vault1.getAddress());
      expect(config.vault).to.equal(await vault1.getAddress());
      expect(config.targetWeight).to.equal(targetWeight);
      expect(config.isActive).to.equal(true);
    });

    it("should reject vault with wrong asset", async function () {
      const { nexusVault, admin } = await loadFixture(deployNexusVaultFixture);

      // Deploy mock vault with different asset
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const wrongAsset = await MockERC20.deploy("Wrong", "WRONG", 18);

      const MockVault = await ethers.getContractFactory("MockERC4626");
      const wrongVault = await MockVault.deploy(await wrongAsset.getAddress(), "Wrong", "W");

      await expect(
        nexusVault.admin
          .connect(admin)
          .addVault(
            await wrongVault.getAddress(),
            ethers.parseEther("1"),
            ethers.parseEther("1"),
            0
          )
      ).to.be.revertedWithCustomError(nexusVault.admin, "AssetMismatch");
    });

    it("should deactivate and activate vault", async function () {
      const { nexusVault, vault1, admin } = await loadFixture(deployNexusVaultFixture);

      await nexusVault.admin
        .connect(admin)
        .addVault(
          await vault1.getAddress(),
          ethers.parseEther("1"),
          ethers.parseEther("1"),
          0
        );

      expect(await nexusVault.view.activeVaultCount()).to.equal(1);

      await nexusVault.admin.connect(admin).deactivateVault(await vault1.getAddress());
      expect(await nexusVault.view.activeVaultCount()).to.equal(0);

      await nexusVault.admin.connect(admin).activateVault(await vault1.getAddress());
      expect(await nexusVault.view.activeVaultCount()).to.equal(1);
    });
  });

  describe("ERC4626 Operations", function () {
    async function setupWithVault() {
      const fixture = await loadFixture(deployNexusVaultFixture);
      const { nexusVault, vault1, admin, usdc, user1, diamondAddress } = fixture;

      // Add vault
      await nexusVault.admin
        .connect(admin)
        .addVault(
          await vault1.getAddress(),
          ethers.parseEther("1"),
          ethers.parseEther("1"),
          0
        );

      // Approve USDC
      await usdc.connect(user1).approve(diamondAddress, ethers.MaxUint256);

      return fixture;
    }

    it("should deposit and receive shares", async function () {
      const { nexusVault, user1 } = await setupWithVault();

      const depositAmount = ethers.parseUnits("1000", 6);

      const tx = await nexusVault.core.connect(user1).deposit(depositAmount, user1.address);
      await tx.wait();

      const shares = await nexusVault.erc20.balanceOf(user1.address);
      expect(shares).to.be.gt(0);
    });

    it("should preview deposit correctly", async function () {
      const { nexusVault } = await setupWithVault();

      const depositAmount = ethers.parseUnits("1000", 6);
      const previewShares = await nexusVault.view.previewDeposit(depositAmount);

      // First deposit should be 1:1
      expect(previewShares).to.equal(depositAmount);
    });

    it("should withdraw assets", async function () {
      const { nexusVault, usdc, user1 } = await setupWithVault();

      const depositAmount = ethers.parseUnits("1000", 6);
      await nexusVault.core.connect(user1).deposit(depositAmount, user1.address);

      const balanceBefore = await usdc.balanceOf(user1.address);

      const withdrawAmount = ethers.parseUnits("500", 6);
      await nexusVault.core.connect(user1).withdraw(withdrawAmount, user1.address, user1.address);

      const balanceAfter = await usdc.balanceOf(user1.address);
      expect(balanceAfter - balanceBefore).to.equal(withdrawAmount);
    });

    it("should redeem shares", async function () {
      const { nexusVault, usdc, user1 } = await setupWithVault();

      const depositAmount = ethers.parseUnits("1000", 6);
      await nexusVault.core.connect(user1).deposit(depositAmount, user1.address);

      const shares = await nexusVault.erc20.balanceOf(user1.address);
      const halfShares = shares / 2n;

      const balanceBefore = await usdc.balanceOf(user1.address);

      await nexusVault.core.connect(user1).redeem(halfShares, user1.address, user1.address);

      const balanceAfter = await usdc.balanceOf(user1.address);
      expect(balanceAfter).to.be.gt(balanceBefore);
    });

    it("should mint exact shares", async function () {
      const { nexusVault, user1 } = await setupWithVault();

      const sharesToMint = ethers.parseUnits("1000", 6);

      await nexusVault.core.connect(user1).mint(sharesToMint, user1.address);

      const shares = await nexusVault.erc20.balanceOf(user1.address);
      expect(shares).to.equal(sharesToMint);
    });
  });

  describe("Access Control", function () {
    it("should allow only admin to add vault", async function () {
      const { nexusVault, vault1, user1 } = await loadFixture(deployNexusVaultFixture);

      await expect(
        nexusVault.admin
          .connect(user1)
          .addVault(
            await vault1.getAddress(),
            ethers.parseEther("1"),
            ethers.parseEther("1"),
            0
          )
      ).to.be.revertedWithCustomError(nexusVault.admin, "OnlyAdmin");
    });

    it("should allow owner to transfer ownership", async function () {
      const { nexusVault, owner, user1 } = await loadFixture(deployNexusVaultFixture);

      await nexusVault.admin.connect(owner).transferOwnership(user1.address);

      expect(await nexusVault.view.owner()).to.equal(user1.address);
    });

    it("should allow admin to add keeper", async function () {
      const { nexusVault, admin, keeper } = await loadFixture(deployNexusVaultFixture);

      await nexusVault.admin.connect(admin).addKeeper(keeper.address);

      expect(await nexusVault.view.isKeeper(keeper.address)).to.equal(true);
    });
  });

  describe("Emergency Controls", function () {
    it("should pause and unpause", async function () {
      const { nexusVault, admin } = await loadFixture(deployNexusVaultFixture);

      await nexusVault.admin.connect(admin).pause();
      expect(await nexusVault.view.paused()).to.equal(true);

      await nexusVault.admin.connect(admin).unpause();
      expect(await nexusVault.view.paused()).to.equal(false);
    });

    it("should prevent deposits when paused", async function () {
      const { nexusVault, admin, user1, usdc, diamondAddress, vault1 } = await loadFixture(
        deployNexusVaultFixture
      );

      // Setup
      await nexusVault.admin
        .connect(admin)
        .addVault(
          await vault1.getAddress(),
          ethers.parseEther("1"),
          ethers.parseEther("1"),
          0
        );
      await usdc.connect(user1).approve(diamondAddress, ethers.MaxUint256);

      // Pause
      await nexusVault.admin.connect(admin).pause();

      // Try deposit
      await expect(
        nexusVault.core.connect(user1).deposit(ethers.parseUnits("100", 6), user1.address)
      ).to.be.revertedWithCustomError(nexusVault.core, "VaultPaused");
    });

    it("should allow only owner to shutdown", async function () {
      const { nexusVault, admin } = await loadFixture(deployNexusVaultFixture);

      await expect(nexusVault.admin.connect(admin).shutdown()).to.be.revertedWithCustomError(
        nexusVault.admin,
        "OnlyOwner"
      );
    });
  });

  describe("Fee Configuration", function () {
    it("should set fee config", async function () {
      const { nexusVault, admin, feeRecipient } = await loadFixture(deployNexusVaultFixture);

      const managementFee = ethers.parseEther("0.02"); // 2%
      const performanceFee = ethers.parseEther("0.20"); // 20%
      const depositFee = ethers.parseEther("0.001"); // 0.1%
      const withdrawFee = ethers.parseEther("0.001"); // 0.1%

      await nexusVault.admin
        .connect(admin)
        .setFeeConfig(
          managementFee,
          performanceFee,
          depositFee,
          withdrawFee,
          feeRecipient.address
        );

      const [mgmt, perf, dep, with_, recipient] = await nexusVault.view.getFeeConfig();
      expect(mgmt).to.equal(managementFee);
      expect(perf).to.equal(performanceFee);
      expect(dep).to.equal(depositFee);
      expect(with_).to.equal(withdrawFee);
      expect(recipient).to.equal(feeRecipient.address);
    });

    it("should reject fee exceeding maximum", async function () {
      const { nexusVault, admin, feeRecipient } = await loadFixture(deployNexusVaultFixture);

      // Try to set 30% management fee (max is 20%)
      await expect(
        nexusVault.admin.connect(admin).setFeeConfig(
          ethers.parseEther("0.30"), // 30% - exceeds max
          0,
          0,
          0,
          feeRecipient.address
        )
      ).to.be.revertedWithCustomError(nexusVault.admin, "FeeExceedsMaximum");
    });
  });

  describe("ERC20 Functionality", function () {
    async function setupWithDeposit() {
      const fixture = await loadFixture(deployNexusVaultFixture);
      const { nexusVault, vault1, admin, usdc, user1, user2, diamondAddress } = fixture;

      await nexusVault.admin
        .connect(admin)
        .addVault(
          await vault1.getAddress(),
          ethers.parseEther("1"),
          ethers.parseEther("1"),
          0
        );

      await usdc.connect(user1).approve(diamondAddress, ethers.MaxUint256);
      await nexusVault.core
        .connect(user1)
        .deposit(ethers.parseUnits("1000", 6), user1.address);

      return fixture;
    }

    it("should transfer shares", async function () {
      const { nexusVault, user1, user2 } = await setupWithDeposit();

      const transferAmount = ethers.parseUnits("100", 6);
      await nexusVault.erc20.connect(user1).transfer(user2.address, transferAmount);

      expect(await nexusVault.erc20.balanceOf(user2.address)).to.equal(transferAmount);
    });

    it("should approve and transferFrom", async function () {
      const { nexusVault, user1, user2 } = await setupWithDeposit();

      const amount = ethers.parseUnits("100", 6);

      await nexusVault.erc20.connect(user1).approve(user2.address, amount);
      expect(await nexusVault.erc20.allowance(user1.address, user2.address)).to.equal(amount);

      await nexusVault.erc20.connect(user2).transferFrom(user1.address, user2.address, amount);
      expect(await nexusVault.erc20.balanceOf(user2.address)).to.equal(amount);
    });
  });
});
