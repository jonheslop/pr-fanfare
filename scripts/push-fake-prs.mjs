#!/usr/bin/env node
// Push fake PR data straight to the device, bypassing the worker (no GitHub
// poll, no Durable Object, no cron). This mirrors what pushApp() in
// src/worker.ts does: POST the rendered Lua app to the relay the device is
// connected to. Edit the data block below and run `node scripts/push-fake-prs.mjs`.
//
// RELAY_BASE / DEVICE_ID default to the values in wrangler.jsonc; override
// either via env, e.g. `DEVICE_ID=abcd1234 node scripts/push-fake-prs.mjs`.

import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const RELAY_BASE = process.env.RELAY_BASE ?? "https://resident.inanimate.tech"
const DEVICE_ID = process.env.DEVICE_ID

// --- The fake queue. Each PR: n=number, t=title, r=owner/repo, a=author,
// adds/dels=line diff (use -1 to hide the diff). Tweak freely. ---
const header = `PR_DATA = {
  {n=3281, t="Add WebGPU backend to the render pipeline",   r="acme/engine", a="ada-lovelace", adds=812, dels=143},
  {n=10474, t="Fix race in the websocket reconnect path",    r="acme/relay",  a="grace-h",      adds=64,  dels=28},
  {n=271,  t="Bump tokio to 1.40 and drop the futures shim",r="acme/core",   a="linus",        adds=19,  dels=204},
  {n=88,   t="Docs: rewrite the getting-started guide",     r="acme/docs",   a="octocat",      adds=330, dels=120},
}
PR_COUNT = 4
PR_BEEP  = true
`

// The Lua app body lives next to this script's parent (../device-apps).
const here = dirname(fileURLToPath(import.meta.url))
const luaPath = join(here, "..", "device-apps", "pr-review.lua")
const code = header + readFileSync(luaPath, "utf8")

const res = await fetch(`${RELAY_BASE}/devices/${DEVICE_ID}/send`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ type: "app", code }),
})

const text = (await res.text()).trim()
console.log(`relay status: ${res.status}  (200 = delivered, 503 = device offline)`)
console.log(`relay body:   ${text || "(empty)"}`)
console.log(`code bytes:   ${code.length}`)

// Non-zero exit on a non-200 so it's scriptable / CI-friendly.
if (res.status !== 200) process.exit(1)
