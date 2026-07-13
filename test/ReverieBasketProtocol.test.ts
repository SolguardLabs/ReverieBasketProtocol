import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

const WAD = ethers.parseEther("1");
const DAY = 24 * 60 * 60;

function usdc(amount: string) {
  return ethers.parseUnits(amount, 6);
}

function eth(amount: string) {
  return ethers.parseEther(amount);
}

async function deployFixture() {
  const [deployer, treasury, alice, bob, strategy] = await ethers.getSigners();

  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const usdcToken = await MockERC20.deploy("USD Coin", "USDC", 6);
  const wethToken = await MockERC20.deploy("Wrapped Ether", "WETH", 18);
  const wstethToken = await MockERC20.deploy("Wrapped Staked Ether", "wstETH", 18);

  const Registry = await ethers.getContractFactory("ComponentRegistry");
  const registry = await Registry.deploy(deployer.address);

  const Oracle = await ethers.getContractFactory("ReveriePriceOracle");
  const oracle = await Oracle.deploy(deployer.address);

  const Policy = await ethers.getContractFactory("ReverieRiskPolicy");
  const policy = await Policy.deploy(deployer.address);

  const Vault = await ethers.getContractFactory("ReverieBasketProtocol");
  const vault = await Vault.deploy(
    deployer.address,
    treasury.address,
    await registry.getAddress(),
    await oracle.getAddress(),
    await policy.getAddress(),
  );

  const tokenAddress = await vault.token();
  const basketToken = await ethers.getContractAt("ReverieBasketToken", tokenAddress);

  const registryRebalancerRole = await registry.REBALANCER_ROLE();
  await registry.grantRole(registryRebalancerRole, await vault.getAddress());

  const heartbeat = 30 * DAY;
  for (const token of [usdcToken, wethToken, wstethToken]) {
    await oracle.configureAsset(
      await token.getAddress(),
      ethers.parseEther("0.01"),
      ethers.parseEther("100000"),
      heartbeat,
    );
  }
  await oracle.setPrice(await usdcToken.getAddress(), WAD);
  await oracle.setPrice(await wethToken.getAddress(), ethers.parseEther("2000"));
  await oracle.setPrice(await wstethToken.getAddress(), ethers.parseEther("2000"));

  await registry.listComponent(await usdcToken.getAddress(), 6, 5_000, 800, 25, 0, true);
  await registry.listComponent(await wethToken.getAddress(), 18, 5_000, 800, 100, 0, true);
  await registry.listComponent(await wstethToken.getAddress(), 18, 0, 800, 100, 0, true);

  await policy.setDelayPolicy(60, 120, 7 * DAY);

  for (const user of [alice, bob, strategy]) {
    await usdcToken.mint(user.address, usdc("1000000"));
    await wethToken.mint(user.address, eth("1000"));
    await wstethToken.mint(user.address, eth("1000"));
    await usdcToken.connect(user).approve(await vault.getAddress(), ethers.MaxUint256);
    await wethToken.connect(user).approve(await vault.getAddress(), ethers.MaxUint256);
    await wstethToken.connect(user).approve(await vault.getAddress(), ethers.MaxUint256);
  }

  return {
    deployer,
    treasury,
    alice,
    bob,
    strategy,
    usdcToken,
    wethToken,
    wstethToken,
    registry,
    oracle,
    policy,
    vault,
    basketToken,
  };
}

async function mintBasket(
  ctx: Awaited<ReturnType<typeof deployFixture>>,
  holder: any,
  amount = "1000",
) {
  await ctx.vault.connect(holder).mint(eth(amount), holder.address);
}

describe("ReverieBasketProtocol", function () {
  it("mints basket shares from weighted component deposits", async function () {
    const ctx = await deployFixture();

    const quote = await ctx.vault.previewMint(eth("1000"));
    expect(quote.deposits.length).to.equal(2);
    expect(quote.deposits[0].amount).to.equal(usdc("500"));
    expect(quote.deposits[1].amount).to.equal(eth("0.25"));

    await expect(ctx.vault.connect(ctx.alice).mint(eth("1000"), ctx.alice.address))
      .to.emit(ctx.vault, "Minted")
      .withArgs(ctx.alice.address, ctx.alice.address, eth("1000"), 2);

    expect(await ctx.basketToken.balanceOf(ctx.alice.address)).to.equal(eth("1000"));
    expect(await ctx.usdcToken.balanceOf(await ctx.vault.getAddress())).to.equal(usdc("500"));
    expect(await ctx.wethToken.balanceOf(await ctx.vault.getAddress())).to.equal(eth("0.25"));
    expect(await ctx.vault.backedSupply()).to.equal(eth("1000"));
  });

  it("redeems active components pro rata", async function () {
    const ctx = await deployFixture();
    await mintBasket(ctx, ctx.alice);

    const beforeUsdc = await ctx.usdcToken.balanceOf(ctx.alice.address);
    const beforeWeth = await ctx.wethToken.balanceOf(ctx.alice.address);

    const quote = await ctx.vault.previewRedeem(eth("100"));
    expect(quote.outputs[0].amount).to.equal(usdc("50"));
    expect(quote.outputs[1].amount).to.equal(eth("0.025"));

    await expect(ctx.vault.connect(ctx.alice).redeem(eth("100"), ctx.alice.address))
      .to.emit(ctx.vault, "Redeemed")
      .withArgs(ctx.alice.address, ctx.alice.address, eth("100"), 2);

    expect(await ctx.basketToken.balanceOf(ctx.alice.address)).to.equal(eth("900"));
    expect((await ctx.usdcToken.balanceOf(ctx.alice.address)) - beforeUsdc).to.equal(usdc("50"));
    expect((await ctx.wethToken.balanceOf(ctx.alice.address)) - beforeWeth).to.equal(eth("0.025"));
  });

  it("harvests component yield and routes fees to treasury", async function () {
    const ctx = await deployFixture();
    await mintBasket(ctx, ctx.alice);

    const vaultBefore = await ctx.wethToken.balanceOf(await ctx.vault.getAddress());
    const treasuryBefore = await ctx.wethToken.balanceOf(ctx.treasury.address);
    const reportHash = ethers.id("harvest:epoch:42");

    await expect(
      ctx.vault.harvest(
        await ctx.wethToken.getAddress(),
        eth("1"),
        ctx.strategy.address,
        reportHash,
      ),
    )
      .to.emit(ctx.vault, "Harvested")
      .withArgs(
        await ctx.wethToken.getAddress(),
        ctx.strategy.address,
        eth("1"),
        eth("0.01"),
        eth("0.99"),
        reportHash,
      );

    expect((await ctx.wethToken.balanceOf(await ctx.vault.getAddress())) - vaultBefore).to.equal(
      eth("0.99"),
    );
    expect((await ctx.wethToken.balanceOf(ctx.treasury.address)) - treasuryBefore).to.equal(
      eth("0.01"),
    );

    const report = await ctx.vault.lastHarvest(await ctx.wethToken.getAddress());
    expect(report.grossAmount).to.equal(eth("1"));
    expect(report.feeAmount).to.equal(eth("0.01"));
    expect(await ctx.vault.harvestedGross(await ctx.wethToken.getAddress())).to.equal(eth("1"));
  });

  it("announces and applies a scheduled weight update", async function () {
    const ctx = await deployFixture();
    const usdcAddress = await ctx.usdcToken.getAddress();
    const wethAddress = await ctx.wethToken.getAddress();

    await expect(
      ctx.vault.announceWeightUpdate(
        [usdcAddress, wethAddress],
        [6_000, 4_000],
        60,
        DAY,
        ethers.id("weights:usdc-tilt"),
      ),
    ).to.emit(ctx.vault, "WeightUpdateAnnounced");

    let pending = await ctx.vault.currentWeightUpdate();
    expect(pending.state).to.equal(1);

    await time.increase(61);
    await expect(ctx.vault.applyWeightUpdate()).to.emit(ctx.vault, "WeightUpdateApplied");

    const usdcComponent = await ctx.registry.getComponent(usdcAddress);
    const wethComponent = await ctx.registry.getComponent(wethAddress);
    expect(usdcComponent.weightBps).to.equal(6_000);
    expect(wethComponent.weightBps).to.equal(4_000);

    pending = await ctx.vault.currentWeightUpdate();
    expect(pending.state).to.equal(0);
  });

  it("substitutes an outgoing component after replacement inventory is received", async function () {
    const ctx = await deployFixture();
    await mintBasket(ctx, ctx.alice);

    const wethAddress = await ctx.wethToken.getAddress();
    const wstethAddress = await ctx.wstethToken.getAddress();

    await expect(
      ctx.vault.announceSubstitution(
        wethAddress,
        wstethAddress,
        120,
        DAY,
        ethers.id("substitution:weth-to-wsteth"),
      ),
    ).to.emit(ctx.vault, "SubstitutionAnnounced");

    let plan = await ctx.vault.currentSubstitution();
    expect(plan.state).to.equal(1);
    expect(plan.outgoing).to.equal(wethAddress);
    expect(plan.incoming).to.equal(wstethAddress);

    await expect(ctx.vault.receiveSubstitutionInventory(eth("0.25"), ctx.strategy.address)).to.emit(
      ctx.vault,
      "SubstitutionInventoryReceived",
    );

    plan = await ctx.vault.currentSubstitution();
    expect(plan.state).to.equal(2);

    await time.increase(121);
    await expect(ctx.vault.completeSubstitution()).to.emit(ctx.vault, "SubstitutionCompleted");

    const outgoing = await ctx.registry.getComponent(wethAddress);
    const incoming = await ctx.registry.getComponent(wstethAddress);
    expect(outgoing.status).to.equal(4);
    expect(outgoing.redeemable).to.equal(false);
    expect(incoming.status).to.equal(1);
    expect(incoming.weightBps).to.equal(5_000);

    const active = await ctx.registry.activeComponents();
    expect(active).to.deep.equal([await ctx.usdcToken.getAddress(), wstethAddress]);
  });
});
