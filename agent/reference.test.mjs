import assert from "node:assert/strict";
import test from "node:test";
import { gapBps, parseHashKeyTicker, referenceLine, unavailableLine } from "./reference.mjs";

const BODY = `[{"s":"HSKUSDT","p":"0.0872"}]`;

test("pins the HashKey ticker parse and the bps gap", () => {
    const parsed = parseHashKeyTicker(BODY);
    assert.equal(parsed.source, "HashKey exchange");
    assert.equal(parsed.symbol, "HSKUSDT");
    assert.equal(parsed.price, "8720000");
    assert.equal(gapBps("8754700", parsed.price).toString(), "-39");

    const view = referenceLine(parsed, "8754700");
    assert.equal(view.price, "8720000");
    assert.equal(view.gapBps, "-39");
    assert.equal(
        view.line,
        "HashKey exchange HSKUSDT 0.0872 USDT, -39 bps from the desk fair price.",
    );
    assert.equal(view.line.includes("mock"), false);
});

test("a missing ticker has no price", () => {
    const line = unavailableLine();
    assert.match(line, /No public HashKey exchange/);
    assert.equal(/\d/.test(line), false);
    assert.throws(() => parseHashKeyTicker("[]"));
    assert.throws(() => parseHashKeyTicker(`[{"s":"HSKUSDT","p":"0"}]`));
});
