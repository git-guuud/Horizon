import { formatUnits } from "./format.mjs";

const CONTRACT = { quote: "quote", cap: "policy", pull: "policy", fill: "policy" };

/** What the command box shows after a parse. The fill cap is a policy field, so it is not marked mock. */
export function commandPreview(parsed) {
    const contract = CONTRACT[parsed.kind] ?? "policy";
    const lines = [
        parsed.summary,
        `Call ${parsed.fn} on the ${contract} contract. Checked on this machine.`,
    ];
    if (parsed.intent) {
        lines.push(
            `Intent size ${formatUnits(parsed.intent.size, 18)} WHSK, limit ${formatUnits(parsed.intent.limit, 8, 6)} USDT, from the fork fair price.`,
        );
    }
    return { lines, mock: null };
}
