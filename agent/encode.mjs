import { execFileSync } from "node:child_process";

/** Calls the operator may send. Withdraw, pause, and key changes are absent on purpose. */
export const ALLOWED = {
    widenWidth: "widenWidth(uint256)",
    tightenWidth: "tightenWidth(uint256,uint256,bytes)",
    lowerInventoryCap: "lowerInventoryCap(address,uint256)",
    raiseInventoryCap: "raiseInventoryCap(address,uint256,uint256,bytes)",
    narrowBand: "narrowBand(uint256)",
    widenBand: "widenBand(uint256,uint256,bytes)",
    lowerFillCap: "lowerFillCap(uint256)",
    raiseFillCap: "raiseFillCap(uint256,uint256,bytes)",
};

export function encodeCall(parsed, traderSignature, ownerSignature) {
    const signature = ALLOWED[parsed.fn];
    if (!signature || traderSignature) throw new Error("ENCODE");
    const args = argsFor(parsed, ownerSignature);
    return { calldata: cast("calldata", [signature, ...args]), reasonHash: null };
}

function argsFor(parsed, ownerSignature) {
    const { fn, args } = parsed;
    if (fn === "widenWidth") return [args.newWidth];
    if (fn === "narrowBand") return [args.newBand];
    if (fn === "lowerFillCap") return [args.newCap];
    if (fn === "lowerInventoryCap") return [args.token, args.newCap];
    if (fn === "tightenWidth") return [args.newWidth, args.deadline, ownerSignature];
    if (fn === "widenBand") return [args.newBand, args.deadline, ownerSignature];
    if (fn === "raiseFillCap") return [args.newCap, args.deadline, ownerSignature];
    if (fn === "raiseInventoryCap") return [args.token, args.newCap, args.deadline, ownerSignature];
    throw new Error("ENCODE");
}

function cast(tool, args) {
    return execFileSync("cast", [tool, ...args], { encoding: "utf8" }).trim();
}
