import { parseCommand } from "../agent/parse.mjs";
import { unavailableLine } from "../agent/reference.mjs";
import { formatBps, formatUnits, group, shortHash } from "./format.mjs";
import { commandPreview } from "./preview.mjs";

const REFUSAL = {
    UNKNOWN: "That clause is not one of the four desk commands.",
    NEEDS_OWNER: "That loosens a limit. Attach the owner's signature.",
    UNCHANGED: "That limit is already set.",
    BAD_AMOUNT: "That amount is not a limit this desk can set.",
    BAD_STATE: "The fork snapshot is missing a figure this check needs.",
    ENCODE: "The command did not become calldata.",
};

const EXAMPLES = [
    "quote 40 bps",
    "max 1,000 USDT of inventory",
    "pull if HSK moves 0.5% from the oracle",
    "fill intents up to 500 USDT",
    "withdraw 1 WHSK",
];

const fair = document.querySelector("#fair");
const feed = document.querySelector("#feed");
const reference = document.querySelector("#reference");
const source = document.querySelector("#source");
const range = document.querySelector("#range");
const inventory = document.querySelector("#inventory");
const depth = document.querySelector("#depth");
const ticket = document.querySelector("#ticket");
const paths = document.querySelector("#paths");
const preflight = document.querySelector("#preflight");
const result = document.querySelector("#command-result");
const form = document.querySelector("#command-form");
const command = document.querySelector("#command");
const signature = document.querySelector("#signature");
const examples = document.querySelector("#examples");

let limits = null;

const demo = await load();
if (demo) render(demo);
wire(demo);

async function load() {
    try {
        const response = await fetch("/web/demo.json");
        if (!response.ok) throw new Error("missing");
        return await response.json();
    } catch {
        fair.textContent = "The fork snapshot is not on this machine. Run the language screen test, then reload.";
        return null;
    }
}

function render(demo) {
    limits = { ...demo.limits };
    source.textContent = demo.source;
    fair.textContent = `${formatUnits(demo.feed.price, 8, 6)} USDT`;
    const feedName = demo.feed.name === "TWAP" ? "30-minute pool TWAP" : demo.feed.name;
    feed.textContent = `USDT for 1 WHSK, from the ${feedName}. APRO HSK/USD reverted: ${demo.feed.aproRevert}.`;
    showReference(demo.feed.price);

    range.replaceChildren(
        line(`Ticks ${demo.range.tickLower} to ${demo.range.tickUpper}, width ${formatBps(demo.range.widthBps)}.`),
        line(`Pool tick ${demo.range.poolTick} sits ${place(demo.range)}.`),
        line(`Position ${group(demo.range.positionId)}. ${demo.range.usedTwap ? "The mint used the TWAP." : "The mint used APRO."}`),
    );

    inventory.replaceChildren(
        bar("WHSK", demo.inventory.whsk, demo.inventory.whskCap, 18),
        bar("USDT", demo.inventory.usdt, demo.inventory.usdtCap, 6),
        line("Balances before the inventory fill, measured against the caps."),
        line(`Fill cap ${formatUnits(demo.limits.maxFillUsdt, 6)} USDT, read from the policy.`),
    );

    const rose = BigInt(demo.depth.liquidityAfter) > BigInt(demo.depth.liquidityBefore);
    const fell = BigInt(demo.depth.liquidityAfter) < BigInt(demo.depth.liquidityBefore);
    depth.replaceChildren(
        line(`${formatUnits(demo.depth.whskOutBefore, 18)} WHSK out for ${formatUnits(demo.depth.probeUsdt, 6)} USDT before the mint.`),
        line(`${formatUnits(demo.depth.whskOutAfter, 18)} WHSK out for the same size after the mint.`),
        line(`In-range liquidity ${group(demo.depth.liquidityBefore)} before, ${group(demo.depth.liquidityAfter)} after.${rose ? " It rose." : ""}${fell ? " It fell." : ""}`),
    );

    const fill = demo.paths.fill;
    ticket.replaceChildren(
        el("h2", {}, ["Intent"]),
        line("Buy WHSK from the vault."),
        line(`${formatUnits(fill.size, 18)} WHSK at a limit of ${formatUnits(fill.limit, 8, 6)} USDT.`),
        line(`Fair ${formatUnits(fill.mid, 8, 6)}, spread ${formatBps(fill.spread)}.`),
        line(`Trader paid ${formatUnits(fill.paid, 6)} USDT. Residual ${formatUnits(fill.residual, 18)} WHSK.`),
        line(`Vault after: ${formatUnits(fill.whskAfter, 18)} WHSK and ${formatUnits(fill.usdtAfter, 6)} USDT.`),
        line(`Reason ${fill.reason}.`),
        el("p", {}, [el("code", {}, [fill.reasonHash])]),
        el("p", { class: "ok-line" }, ["Filled from inventory."]),
        el("p", { class: "muted" }, [`Operator withdraw reverted ${demo.withdraw.error}. Fills settle through the vault.`]),
    );

    paths.replaceChildren(
        path("Naked pool", `${formatUnits(demo.paths.naked.quotedOut, 18)} WHSK quoted for a ${formatUnits(demo.paths.naked.size, 18)} WHSK buy. The router reverted: ${demo.paths.naked.routerRevert}.`),
        path("Desk fill", `The same size filled. Vault USDT is ${formatUnits(demo.paths.fill.usdtAfter, 6)}.`),
        path(demo.paths.outside.reason, `The ask sat outside the band. ${demo.paths.outside.reasonHash}`),
        path(
            `${demo.paths.stale.staleReason} then ${demo.paths.stale.haltedReason}`,
            `The stale fill reverted ${demo.paths.stale.staleReason}. After a fresh observation the halt still reverted ${demo.paths.stale.haltedReason}. Operator resume reverted ${demo.paths.stale.operatorResume}.${demo.paths.stale.ownerResumed ? " The owner resumed." : ""}`,
        ),
    );

    preflight.replaceChildren(
        el("h2", {}, ["Preflight"]),
        el("p", { class: "stamp" }, [`quote 10 bps without a signature: ${demo.preflight.needsOwner}.`]),
        el("p", { class: "stamp" }, [
            `${demo.preflight.badSignature.command} with a bad signature: ${demo.preflight.badSignature.reason}. eth_call on the fork, not broadcast. ${shortHash(demo.preflight.badSignature.reasonHash)}`,
        ]),
        el("p", { class: "stamp" }, [
            `${demo.preflight.outsideFill.command}: ${demo.preflight.outsideFill.reason}. eth_call on the fork, not broadcast. ${shortHash(demo.preflight.outsideFill.reasonHash)}`,
        ]),
    );
}

async function showReference(fairRaw) {
    try {
        const response = await fetch(`/web/reference.json?fair=${fairRaw}`);
        if (!response.ok) throw new Error("reference");
        const body = await response.json();
        if (!body.line) throw new Error("reference");
        reference.textContent = body.line;
    } catch {
        reference.textContent = unavailableLine();
    }
}

function wire(demo) {
    for (const example of EXAMPLES) {
        const button = el("button", { type: "button" }, [example]);
        button.addEventListener("click", () => {
            command.value = example;
            command.focus();
        });
        examples.append(button);
    }
    form.addEventListener("submit", (event) => {
        event.preventDefault();
        result.replaceChildren();
        if (!demo) {
            result.append(line(REFUSAL.BAD_STATE));
            return;
        }
        const parsed = parseCommand(command.value, limits, signature.value.trim());
        if (!parsed.ok) {
            result.append(el("p", { class: "stamp" }, [REFUSAL[parsed.code] ?? parsed.code]));
            return;
        }
        limits = { ...limits, ...parsed.next };
        const preview = commandPreview(parsed);
        for (const text of preview.lines) result.append(line(text));
        if (preview.mock) result.append(el("p", { class: "mock" }, [preview.mock]));
    });
}

function place(range) {
    const tick = Number(range.poolTick);
    const lower = Number(range.tickLower);
    const upper = Number(range.tickUpper);
    if (tick < lower) return "below the range";
    if (tick >= upper) return "above the range";
    return "inside the range";
}

function bar(label, balance, cap, decimals) {
    const have = BigInt(balance);
    const limit = BigInt(cap);
    const pct = limit === 0n ? 0 : Number((have * 10000n) / limit) / 100;
    const width = Math.min(pct, 100);
    const track = el("div", { class: "bar" }, [el("span", {}, [])]);
    track.firstChild.style.width = `${width}%`;
    const wrap = el("div", {}, [
        line(`${label} ${formatUnits(have, decimals)} of ${formatUnits(limit, decimals)} cap.`),
        track,
    ]);
    return wrap;
}

function path(title, body) {
    return el("div", { class: "path" }, [el("strong", {}, [title]), el("span", {}, [body])]);
}

function line(text) {
    return el("p", {}, [text]);
}

function el(tag, attrs, children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
    for (const child of children) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    return node;
}
