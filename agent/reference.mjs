import { formatUnits } from "../web/format.mjs";

export const SOURCE = "HashKey exchange";
export const SYMBOL = "HSKUSDT";
export const TICKER_URL = "https://api-glb.hashkey.com/quote/v1/ticker/price?symbol=HSKUSDT";

const PRICE = /^\d+(\.\d+)?$/;

/// @param {string} body HashKey public ticker JSON. No key.
export function parseHashKeyTicker(body) {
    const rows = JSON.parse(body);
    if (!Array.isArray(rows)) throw new Error("reference");
    const row = rows.find((item) => item && item.s === SYMBOL);
    if (!row || typeof row.p !== "string" || !PRICE.test(row.p)) throw new Error("reference");
    const price = decimalToRaw(row.p, 8);
    if (price === "0") throw new Error("reference");
    return { source: SOURCE, symbol: SYMBOL, price };
}

/// Signed distance of the reference from the desk fair price, in bps. Both prices are 8-decimal raw.
export function gapBps(fairRaw, referenceRaw) {
    const fair = BigInt(fairRaw);
    const reference = BigInt(referenceRaw);
    if (fair <= 0n || reference <= 0n) throw new Error("price");
    return ((reference - fair) * 10_000n) / fair;
}

export function referenceLine(parsed, fairRaw) {
    const gap = gapBps(fairRaw, parsed.price);
    return {
        source: parsed.source,
        symbol: parsed.symbol,
        price: parsed.price,
        gapBps: gap.toString(),
        line: `${parsed.source} ${parsed.symbol} ${formatUnits(parsed.price, 8, 6)} USDT, ${gap.toString()} bps from the desk fair price.`,
    };
}

export function unavailableLine() {
    return "No public HashKey exchange HSK/USDT reference is available. No price is shown.";
}

export async function loadHashKeyReference(fairRaw, fetchImpl = globalThis.fetch) {
    const response = await fetchImpl(TICKER_URL);
    if (!response.ok) throw new Error("reference");
    const parsed = parseHashKeyTicker(await response.text());
    return referenceLine(parsed, fairRaw);
}

function decimalToRaw(text, decimals) {
    const [whole, frac = ""] = text.split(".");
    if (frac.length > decimals) throw new Error("reference");
    return BigInt(whole + frac.padEnd(decimals, "0")).toString();
}
