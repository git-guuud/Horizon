import { readFileSync, writeFileSync } from "node:fs";
import { encodeCall } from "./encode.mjs";
import { parseCommand } from "./parse.mjs";

const requestPath = process.argv[2] ?? "cache/language-request.json";
const responsePath = process.argv[3] ?? "cache/language-response.json";

const request = JSON.parse(readFileSync(requestPath, "utf8"));
const parsed = parseCommand(request.command, request.state, request.ownerSignature);
const response = { ...parsed };

if (parsed.ok) {
    try {
        const encoded = encodeCall(parsed, request.traderSignature, request.ownerSignature);
        response.calldata = encoded.calldata;
        response.reasonHash = encoded.reasonHash;
    } catch {
        response.ok = false;
        response.code = "ENCODE";
        response.calldata = null;
    }
} else {
    response.calldata = null;
    response.reasonHash = null;
}

writeFileSync(responsePath, JSON.stringify(response, (_key, value) => (typeof value === "bigint" ? value.toString() : value)));
