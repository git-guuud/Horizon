# Desk

On-chain dealing desk for HashKey Chain. Spec: `IDEA.md`.

## Pin the WHSK/USDT market

The pin script reads a chain id 177 fork and writes `addresses.json`. That file is output, not a source of addresses.

```bash
forge script script/PinMarket.s.sol --fork-url hashkey -vv
forge test
```

## Desk screen

`forge test --match-test test_fork_languageDryRunAndScreen` writes `web/demo.json` from a chain 177 fork. It does not broadcast. Then:

```bash
node --test agent/parse.test.mjs agent/reference.test.mjs web/format.test.mjs
node agent/serve.mjs
```

Open http://127.0.0.1:4173. The four fork paths, the reason codes, and the command check are on that page. A command that is not in the closed set is refused. Loosening a limit needs an owner signature. The page has no withdraw.
