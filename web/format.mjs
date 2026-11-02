export function formatUnits(raw, decimals, maxFrac = 4) {
    const value = BigInt(raw);
    const scale = 10n ** BigInt(decimals);
    const whole = value / scale;
    const fracFull = (value % scale).toString().padStart(Number(decimals), "0");
    const frac = fracFull.slice(0, maxFrac).replace(/0+$/, "");
    const grouped = group(whole);
    if (!frac) return grouped;
    return `${grouped}.${frac}`;
}

export function formatBps(raw) {
    const bps = BigInt(raw);
    if (bps % 100n === 0n) return `${bps.toString()} bps (${(bps / 100n).toString()}%)`;
    return `${bps.toString()} bps`;
}

export function group(value) {
    return value.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

export function shortHash(hash) {
    if (!hash || hash.length < 12) return hash ?? "";
    return `${hash.slice(0, 8)}…${hash.slice(-4)}`;
}
