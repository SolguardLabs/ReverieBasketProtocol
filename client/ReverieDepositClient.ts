import { IERC20, ReverieBasketProtocol } from "../typechain-types";
import { ethers } from "ethers";

export type DepositRequirement = {
  asset: string;
  amount: bigint;
  balance: bigint;
  allowance: bigint;
  balanceShortfall: bigint;
  allowanceShortfall: bigint;
};

export type DepositPlan = {
  basketAmount: bigint;
  grossValue: bigint;
  receiver: string;
  requirements: DepositRequirement[];
  ready: boolean;
};

const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner,address spender) view returns (uint256)",
];

/** Read-only preparation of a basket mint from the same quote used by the vault. */
export class ReverieDepositClient {
  constructor(private readonly vault: ReverieBasketProtocol) {}

  async plan(basketAmount: bigint, owner: string, receiver: string): Promise<DepositPlan> {
    if (basketAmount <= 0n) throw new Error("basketAmount must be positive");
    if (!ethers.isAddress(owner) || !ethers.isAddress(receiver)) {
      throw new Error("owner and receiver must be addresses");
    }

    const quote = await this.vault.previewMint(basketAmount);
    const vaultAddress = await this.vault.getAddress();
    const runner = this.vault.runner;
    if (!runner) throw new Error("vault has no provider or signer");

    const requirements = await Promise.all(
      quote.deposits.map(async (deposit) => {
        const token = new ethers.Contract(deposit.asset, ERC20_ABI, runner) as unknown as IERC20;
        const [balance, allowance] = await Promise.all([
          token.balanceOf(owner),
          token.allowance(owner, vaultAddress),
        ]);
        return {
          asset: deposit.asset,
          amount: deposit.amount,
          balance,
          allowance,
          balanceShortfall: deposit.amount > balance ? deposit.amount - balance : 0n,
          allowanceShortfall: deposit.amount > allowance ? deposit.amount - allowance : 0n,
        };
      }),
    );

    return {
      basketAmount,
      grossValue: quote.grossValue,
      receiver,
      requirements,
      ready: requirements.every(
        (item) => item.balanceShortfall === 0n && item.allowanceShortfall === 0n,
      ),
    };
  }
}
