/**
 * Closed desk commands. Anything outside the four patterns is refused.
 * A command that loosens a limit is refused unless a 65-byte owner signature is attached.
 * The signature is checked on chain. This module does not hold a key and does not withdraw.
 */

const BPS = 10_000n;
const SIG = /^0x[0-9a-fA-F]{130}$/;
const ADDR = /^0x[0-9a-fA-F]{40}$/;

const COMMANDS = [
    { kind: "quote", re: /^quote (\d+) bps$/ },
    { kind: "cap", re: /^max (\d+) (whsk|usdt) of inventory$/ },
    { kind: "pull", re: /^pull if hsk moves (\d+(?:\.\d+)?)% from the oracle$/ },
    { kind: "fill", re: /^fill intents up to (\d+) usdt$/ },
];

export function parseCommand(text, state, ownerSignature) {
    const raw = String(text ?? "").trim().replace(/\s+/g, " ");
    const norm = raw.toLowerCase().replace(/(\d),(?=\d)/g, "$1");
    const matched = COMMANDS.map((command) => ({ command, match: command.re.exec(norm) })).find((row) => row.match);
    if (!matched) return refuse("UNKNOWN", raw);

    try {
        const action = build(matched.command.kind, matched.match, raw, state);
        if (action.loosens && !SIG.test(ownerSignature ?? "")) return { ...action, ok: false, code: "NEEDS_OWNER" };
        return { ...action, ok: true, code: null };
    } catch (err) {
        if (err instanceof ParseError) return refuse(err.code, raw);
        throw err;
    }
}

function build(kind, match, raw, state) {
    if (kind === "quote") return quote(BigInt(match[1]), state);
    if (kind === "cap") return cap(BigInt(match[1]), match[2], state);
    if (kind === "pull") return pull(match[1], state);
    return fill(BigInt(match[1]), state);
}

function quote(width, state) {
    const current = need(state, "widthBps");
    if (width === 0n || width >= BPS) throw new ParseError("BAD_AMOUNT");
    if (width === current) throw new ParseError("UNCHANGED");
    const loosens = width < current;
    const fn = loosens ? "tightenWidth" : "widenWidth";
    const args = { newWidth: str(width) };
    if (loosens) attach(args, state);
    return plan("quote", fn, address(state, "quote"), loosens, args, { widthBps: str(width) }, null);
}

function cap(human, tokenName, state) {
    const decimals = tokenName === "whsk" ? need(state, "whskDecimals") : need(state, "usdtDecimals");
    const current = tokenName === "whsk" ? need(state, "whskCap") : need(state, "usdtCap");
    const raw = human * 10n ** decimals;
    if (human === 0n || raw > 2n ** 256n - 1n) throw new ParseError("BAD_AMOUNT");
    if (raw === current) throw new ParseError("UNCHANGED");
    const token = tokenName === "whsk" ? address(state, "whsk") : address(state, "usdt");
    const loosens = raw > current;
    const fn = loosens ? "raiseInventoryCap" : "lowerInventoryCap";
    const args = { token, newCap: str(raw) };
    if (loosens) attach(args, state);
    const next = tokenName === "whsk" ? { whskCap: str(raw) } : { usdtCap: str(raw) };
    return plan("cap", fn, address(state, "policy"), loosens, args, next, null);
}

function pull(percent, state) {
    const band = percentToBps(percent);
    if (band === null) throw new ParseError("BAD_AMOUNT");
    const current = need(state, "bandBps");
    if (band === current) throw new ParseError("UNCHANGED");
    const loosens = band > current;
    const fn = loosens ? "widenBand" : "narrowBand";
    const args = { newBand: str(band) };
    if (loosens) attach(args, state);
    return plan("pull", fn, address(state, "policy"), loosens, args, { bandBps: str(band) }, null);
}

function fill(human, state) {
    const decimals = need(state, "usdtDecimals");
    const capUsdt = need(state, "maxFillUsdt");
    if (human === 0n) throw new ParseError("BAD_AMOUNT");
    const usdtRaw = human * 10n ** decimals;
    if (usdtRaw > 2n ** 256n - 1n) throw new ParseError("BAD_AMOUNT");
    if (usdtRaw === capUsdt) throw new ParseError("UNCHANGED");
    const loosens = usdtRaw > capUsdt;
    const fn = loosens ? "raiseFillCap" : "lowerFillCap";
    const args = { newCap: str(usdtRaw) };
    if (loosens) attach(args, state);
    return plan("fill", fn, address(state, "policy"), loosens, args, { maxFillUsdt: str(usdtRaw) }, null);
}

function plan(kind, fn, to, loosens, args, next, intent) {
    return { ok: true, code: null, kind, fn, to, loosens, args, next, intent, summary: summary(kind, fn, next) };
}

function summary(kind, fn, next) {
    if (kind === "quote") return `Posted width ${next.widthBps} bps via ${fn}.`;
    if (kind === "cap" && next.whskCap) return `WHSK inventory cap via ${fn}.`;
    if (kind === "cap") return `USDT inventory cap via ${fn}.`;
    if (kind === "pull") return `Pull band ${next.bandBps} bps via ${fn}.`;
    return `Fill cap via ${fn}.`;
}

function attach(args, state) {
    args.deadline = str(need(state, "deadline"));
    return args;
}

function refuse(code, raw) {
    return {
        ok: false,
        code,
        kind: null,
        fn: null,
        to: null,
        loosens: false,
        args: null,
        next: null,
        intent: null,
        summary: raw ? `Refused: ${raw}` : "Refused.",
    };
}

function percentToBps(raw) {
    const match = /^(\d+)(?:\.(\d+))?$/.exec(raw);
    if (!match) return null;
    const frac = match[2] ?? "";
    if (frac.length > 2) return null;
    const bps = BigInt(match[1]) * 100n + BigInt((frac + "00").slice(0, 2));
    if (bps === 0n || bps >= BPS) return null;
    return bps;
}

function need(state, key) {
    const value = uint(state?.[key]);
    if (value === null) throw new ParseError("BAD_STATE");
    return value;
}

function address(state, key) {
    const value = state?.[key];
    if (typeof value !== "string" || !ADDR.test(value)) throw new ParseError("BAD_STATE");
    return value;
}

function uint(value) {
    if (typeof value === "bigint" && value >= 0n) return value;
    if (typeof value === "number" && Number.isSafeInteger(value) && value >= 0) return BigInt(value);
    if (typeof value === "string" && /^(0|[1-9]\d*)$/.test(value)) return BigInt(value);
    return null;
}

function str(value) {
    return value.toString();
}

class ParseError extends Error {
    constructor(code) {
        super(code);
        this.code = code;
    }
}
