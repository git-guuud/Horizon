import assert from "node:assert/strict";
import test from "node:test";
import { parseCommand } from "../agent/parse.mjs";
import { commandPreview } from "./preview.mjs";

function deskState(over = {}) {
    return {
        spreadFloor: "30",
        widthBps: "30",
        bandBps: "100",
        whskCap: (10n * 10n ** 18n).toString(),
        usdtCap: (2_000n * 10n ** 6n).toString(),
        maxFillUsdt: (1_000n * 10n ** 6n).toString(),
        fairPrice: (10n ** 8n).toString(),
        whsk: "0xB210D2120d57b758EE163cFfb43e73728c471Cf1",
        usdt: "0xF1B50eD67A9e2CC94Ad3c477779E2d4cBfFf9029",
        policy: "0x1111111111111111111111111111111111111111",
        quote: "0x4444444444444444444444444444444444444444",
        fill: "0x2222222222222222222222222222222222222222",
        pool: "0x4ff515761864e7838B0AdB8b5b2B8B7A068905dC",
        trader: "0x3333333333333333333333333333333333333333",
        nonce: "1",
        expiry: "2000000000",
        deadline: "1900000000",
        quoteScale: (10n ** 20n).toString(),
        whskDecimals: "18",
        usdtDecimals: "6",
        ...over,
    };
}

test("a quote, cap, or pull preview is not marked mock", () => {
    const state = deskState();
    const cases = [
        ["quote 40 bps", "widenWidth", "quote"],
        ["max 1,000 USDT of inventory", "lowerInventoryCap", "policy"],
        ["pull if HSK moves 0.5% from the oracle", "narrowBand", "policy"],
        ["fill intents up to 500 USDT", "lowerFillCap", "policy"],
    ];
    for (const [command, fn, contract] of cases) {
        const parsed = parseCommand(command, state);
        assert.equal(parsed.ok, true, command);
        const preview = commandPreview(parsed);
        assert.equal(preview.mock, null, command);
        const text = preview.lines.join(" ");
        assert.match(text, new RegExp(`Call ${fn} on the ${contract} contract`));
        assert.match(text, /Checked on this machine/);
        assert.doesNotMatch(text, /mock/i);
    }

    const raised = parseCommand("fill intents up to 1,500 USDT", state, `0x${"11".repeat(65)}`);
    const raisedPreview = commandPreview(raised);
    assert.equal(raisedPreview.mock, null);
    assert.match(raisedPreview.lines.join(" "), /Call raiseFillCap on the policy contract/);
    assert.doesNotMatch(raisedPreview.lines.join(" "), /mock/i);
});
