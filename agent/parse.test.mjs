import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import test from "node:test";
import { encodeCall } from "./encode.mjs";
import { parseCommand } from "./parse.mjs";
import { REASONS, reasonName } from "./reasons.mjs";
import { execFileSync } from "node:child_process";

const SIG = `0x${"11".repeat(65)}`;

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

test("a wider quote sets the posted width", () => {
    const parsed = parseCommand("quote 40 bps", deskState());
    assert.equal(parsed.ok, true);
    assert.equal(parsed.kind, "quote");
    assert.equal(parsed.fn, "widenWidth");
    assert.equal(parsed.loosens, false);
    assert.equal(parsed.args.newWidth, "40");
    assert.equal(parsed.next.widthBps, "40");
    assert.equal(parsed.to, deskState().quote);
    assert.equal(parsed.next.spreadFloor, undefined);
});

test("a tighter quote with no signature is refused", () => {
    const parsed = parseCommand("quote 10 bps", deskState());
    assert.equal(parsed.ok, false);
    assert.equal(parsed.code, "NEEDS_OWNER");
    assert.equal(parsed.fn, "tightenWidth");
    assert.equal(parsed.loosens, true);
    assert.equal(parsed.to, deskState().quote);
});

test("inventory cap lowers without a signature", () => {
    const parsed = parseCommand("max 1,000 USDT of inventory", deskState());
    assert.equal(parsed.ok, true);
    assert.equal(parsed.fn, "lowerInventoryCap");
    assert.equal(parsed.args.token, deskState().usdt);
    assert.equal(parsed.args.newCap, (1_000n * 10n ** 6n).toString());

    const whsk = parseCommand("max 2 WHSK of inventory", deskState());
    assert.equal(whsk.ok, true);
    assert.equal(whsk.fn, "lowerInventoryCap");
    assert.equal(whsk.args.token, deskState().whsk);
    assert.equal(whsk.args.newCap, (2n * 10n ** 18n).toString());
});

test("pull if HSK moves narrows the band", () => {
    const parsed = parseCommand("pull if HSK moves 0.5% from the oracle", deskState());
    assert.equal(parsed.ok, true);
    assert.equal(parsed.kind, "pull");
    assert.equal(parsed.fn, "narrowBand");
    assert.equal(parsed.args.newBand, "50");
    assert.equal(parsed.loosens, false);
});

test("a lower fill cap calls the policy and does not build a fill", () => {
    const parsed = parseCommand("fill intents up to 500 USDT", deskState());
    assert.equal(parsed.ok, true);
    assert.equal(parsed.kind, "fill");
    assert.equal(parsed.fn, "lowerFillCap");
    assert.equal(parsed.loosens, false);
    assert.equal(parsed.to, deskState().policy);
    assert.equal(parsed.intent, null);
    assert.equal(parsed.args.newCap, (500n * 10n ** 6n).toString());
    assert.equal(parsed.next.maxFillUsdt, (500n * 10n ** 6n).toString());
});

test("a higher fill cap with no signature is refused", () => {
    const parsed = parseCommand("fill intents up to 1,500 USDT", deskState());
    assert.equal(parsed.ok, false);
    assert.equal(parsed.code, "NEEDS_OWNER");
    assert.equal(parsed.fn, "raiseFillCap");
    assert.equal(parsed.loosens, true);
    assert.equal(parsed.intent, null);
    assert.equal(parsed.to, deskState().policy);
});

test("an unknown clause is refused", () => {
    for (const command of ["withdraw 1 WHSK", "quote 40 bps and withdraw", "quote thirty bps", "", "pull if HSK moves 1%"]) {
        const parsed = parseCommand(command, deskState());
        assert.equal(parsed.ok, false, command);
        assert.equal(parsed.code, "UNKNOWN", command);
        assert.equal(parsed.fn, null, command);
        assert.equal(parsed.to, null, command);
    }
});

test("loosening without an owner signature is refused", () => {
    const cases = [
        "quote 10 bps",
        "max 3,000 USDT of inventory",
        "max 11 WHSK of inventory",
        "pull if HSK moves 2% from the oracle",
        "fill intents up to 1,500 USDT",
    ];
    for (const command of cases) {
        const parsed = parseCommand(command, deskState());
        assert.equal(parsed.ok, false, command);
        assert.equal(parsed.code, "NEEDS_OWNER", command);
        assert.equal(parsed.loosens, true, command);
    }
});

test("an attached owner signature lets a loosen through", () => {
    const quote = parseCommand("quote 10 bps", deskState(), SIG);
    assert.equal(quote.ok, true);
    assert.equal(quote.fn, "tightenWidth");
    assert.equal(quote.args.newWidth, "10");
    assert.equal(quote.args.deadline, "1900000000");

    const cap = parseCommand("max 3,000 USDT of inventory", deskState(), SIG);
    assert.equal(cap.ok, true);
    assert.equal(cap.fn, "raiseInventoryCap");

    const pull = parseCommand("pull if HSK moves 2% from the oracle", deskState(), SIG);
    assert.equal(pull.ok, true);
    assert.equal(pull.fn, "widenBand");
    assert.equal(pull.args.newBand, "200");

    const fill = parseCommand("fill intents up to 1,500 USDT", deskState(), SIG);
    assert.equal(fill.ok, true);
    assert.equal(fill.loosens, true);
    assert.equal(fill.fn, "raiseFillCap");
    assert.equal(fill.intent, null);
    assert.equal(fill.args.newCap, (1_500n * 10n ** 6n).toString());
    assert.equal(fill.args.deadline, "1900000000");
    assert.equal(fill.to, deskState().policy);
});

test("the same limit is refused as unchanged", () => {
    assert.equal(parseCommand("quote 30 bps", deskState()).code, "UNCHANGED");
    assert.equal(parseCommand("pull if HSK moves 1% from the oracle", deskState()).code, "UNCHANGED");
    assert.equal(parseCommand("max 2,000 USDT of inventory", deskState()).code, "UNCHANGED");
    assert.equal(parseCommand("fill intents up to 1000 USDT", deskState()).code, "UNCHANGED");
});

test("calldata matches the allowed selectors and never withdraws", () => {
    const source = readFileSync(new URL("./encode.mjs", import.meta.url), "utf8");
    const parser = readFileSync(new URL("./parse.mjs", import.meta.url), "utf8");
    assert.equal(source.includes("withdraw"), false);
    assert.equal(source.includes("setOperator"), false);
    assert.equal(source.includes("transferOwnership"), false);
    assert.equal(source.includes("SpreadFloor"), false);
    assert.equal(parser.includes("SpreadFloor"), false);

    const quote = parseCommand("quote 40 bps", deskState());
    const widened = encodeCall(quote, null, null);
    assert.equal(widened.calldata.slice(0, 10), "0x83406930");

    const tight = parseCommand("quote 10 bps", deskState(), SIG);
    const tightened = encodeCall(tight, null, SIG);
    assert.equal(tightened.calldata.slice(0, 10), "0x50331309");
    assert.equal(tightened.calldata.includes(SIG.slice(2)), true);

    const lower = parseCommand("max 1,000 USDT of inventory", deskState());
    assert.equal(encodeCall(lower, null, null).calldata.slice(0, 10), "0x291ab75b");

    const raised = parseCommand("max 3,000 USDT of inventory", deskState(), SIG);
    assert.equal(encodeCall(raised, null, SIG).calldata.slice(0, 10), "0x5c55aa04");

    const narrow = parseCommand("pull if HSK moves 0.5% from the oracle", deskState());
    assert.equal(encodeCall(narrow, null, null).calldata.slice(0, 10), "0x908e7ce8");

    const wide = parseCommand("pull if HSK moves 2% from the oracle", deskState(), SIG);
    assert.equal(encodeCall(wide, null, SIG).calldata.slice(0, 10), "0x42216c8b");

    const fill = parseCommand("fill intents up to 500 USDT", deskState());
    const encoded = encodeCall(fill, null, null);
    assert.equal(encoded.calldata.slice(0, 10), "0x4ba3a7d0");
    assert.equal(encoded.reasonHash, null);
    assert.equal(fill.intent, null);

    const raisedFill = parseCommand("fill intents up to 1,500 USDT", deskState(), SIG);
    const raisedEncoded = encodeCall(raisedFill, null, SIG);
    assert.equal(raisedEncoded.calldata.slice(0, 10), "0x9c204fb7");
    assert.equal(raisedEncoded.calldata.includes(SIG.slice(2)), true);
});

test("reason names are keccak256 of the label", () => {
    for (const [name, hash] of Object.entries(REASONS)) {
        const got = execFileSync("cast", ["keccak", name], { encoding: "utf8" }).trim();
        assert.equal(got, hash, name);
        assert.equal(reasonName(hash), name);
    }
});
