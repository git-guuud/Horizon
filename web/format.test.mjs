import assert from "node:assert/strict";
import test from "node:test";
import { formatBps, formatUnits } from "./format.mjs";

test("formats token amounts and bps from raw chain values", () => {
    assert.equal(formatUnits(100_000n * 10n ** 18n, 18), "100,000");
    assert.equal(formatUnits(100_300n * 10n ** 6n, 6), "100,300");
    assert.equal(formatUnits(8_710_000n, 8, 6), "0.0871");
    assert.equal(formatBps(100), "100 bps (1%)");
    assert.equal(formatBps(50), "50 bps");
});
