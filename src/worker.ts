import { DeviceAgent, routeDeviceRequest } from "@inanimate/resident/cloudflare"
import { getAgentByName } from "agents"
// The Lua app body, imported as text (see the "Text" rule in wrangler.jsonc).
// We prepend PR_DATA / PR_COUNT / PR_BEEP to it before pushing to the device.
import APP_BODY from "../device-apps/pr-review.lua"

type PR = { num: number; title: string; repo: string }

// Re-push at least this often so a rebooted device repaints even when the
// queue hasn't changed. last_push_ms only advances on a successful (200) relay
// push, so a device that was offline repaints within one poll of coming back.
const HEARTBEAT_MS = 10 * 60 * 1000

// Hide long-open PRs: only surface review requests on PRs created within this
// many days. Filtering server-side keeps total_count consistent with the list.
const MAX_AGE_DAYS = 10

// YYYY-MM-DD (UTC) for `days` ago — the lower bound for the `created:` filter.
function sinceDate(days: number): string {
  return new Date(Date.now() - days * 86400_000).toISOString().slice(0, 10)
}

// --- GitHub: the PRs currently awaiting this token-owner's review ---
async function fetchReviewQueue(token: string): Promise<{ prs: PR[]; count: number }> {
  const q =
    "is:open is:pull-request review-requested:@me archived:false " +
    "-label:platform " +
    `created:>=${sinceDate(MAX_AGE_DAYS)}`
  const url =
    `https://api.github.com/search/issues?q=${encodeURIComponent(q)}` +
    `&per_page=20&sort=created&order=desc`
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "resident-pr-review",
    },
  })
  if (!res.ok) {
    throw new Error(`GitHub search ${res.status}: ${await res.text()}`)
  }
  const json = (await res.json()) as {
    total_count: number
    items: Array<{ number: number; title: string; repository_url: string }>
  }
  const prs = json.items.slice(0, 12).map((it) => ({
    num: it.number,
    title: it.title ?? "",
    repo: (it.repository_url ?? "").split("/repos/")[1] ?? "",
  }))
  return { prs, count: json.total_count }
}

// --- Lua codegen ---
// Quote a JS string as a Lua double-quoted literal: strip to printable ASCII
// (the TFT font is ASCII-only), cap length to bound code size, escape \ and ".
function luaStr(s: string): string {
  const ascii = s.replace(/[^\x20-\x7E]/g, "").slice(0, 80)
  return `"${ascii.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`
}

function renderApp(prs: PR[], count: number, beep: boolean): string {
  const items = prs
    .map((p) => `{n=${p.num},t=${luaStr(p.title)},r=${luaStr(p.repo)}}`)
    .join(",")
  const header =
    `PR_DATA = {${items}}\n` +
    `PR_COUNT = ${count}\n` +
    `PR_BEEP = ${beep ? "true" : "false"}\n`
  return header + APP_BODY
}

/**
 * Polls the GitHub review queue and pushes a freshly-rendered app to the
 * device by POSTing to the relay the device is connected to (the hosted
 * resident.inanimate.tech by default — its TLS root is one the firmware
 * trusts). All "what's new" logic lives here; the device just runs the app.
 *
 * This Durable Object is used purely as a scheduler + state store; no device
 * connects to it directly.
 */
class PRReviewAgent extends DeviceAgent<Env> {
  async onRequest(request: Request): Promise<Response> {
    const subpath = new URL(request.url).pathname.replace(/^\/devices\/[^/]+/, "")
    if (subpath === "/poll" && request.method === "POST") {
      await this.pollAndPush()
      return new Response("polled\n", { status: 200 })
    }
    // Debug: render the exact Lua we'd push for the current queue, as text.
    // Stateless — no push, no storage write. Handy for `curl`-testing.
    if (subpath === "/preview" && request.method === "GET") {
      try {
        const { prs, count } = await fetchReviewQueue(this.env.GITHUB_TOKEN)
        return new Response(renderApp(prs, count, false), {
          headers: { "Content-Type": "text/plain; charset=utf-8" },
        })
      } catch (e) {
        return new Response(`github fetch failed: ${e}\n`, { status: 502 })
      }
    }
    return super.onRequest(request)
  }

  // Push the app to the device via the relay it's connected to. Returns the
  // relay's HTTP status: 200 = delivered, 503 = device not currently connected.
  async pushApp(code: string): Promise<number> {
    const base = this.env.RELAY_BASE ?? "https://resident.inanimate.tech"
    const res = await fetch(`${base}/devices/${this.env.DEVICE_ID}/send`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type: "app", code }),
    })
    return res.status
  }

  async pollAndPush(): Promise<void> {
    let queue: { prs: PR[]; count: number }
    try {
      queue = await fetchReviewQueue(this.env.GITHUB_TOKEN)
    } catch (e) {
      console.error("pollAndPush: github fetch failed", e)
      return
    }

    const numbers = queue.prs.map((p) => p.num)
    const stored = await this.ctx.storage.get<number[]>("last_seen")
    const firstRun = stored === undefined
    const prevSet = new Set(stored ?? [])
    const newOnes = numbers.filter((n) => !prevSet.has(n))
    const setsDiffer =
      firstRun || newOnes.length > 0 || numbers.length !== (stored ?? []).length

    const lastPush = (await this.ctx.storage.get<number>("last_push_ms")) ?? 0
    const stale = Date.now() - lastPush > HEARTBEAT_MS

    if (!setsDiffer && !stale) return

    const beep = !firstRun && newOnes.length > 0
    const status = await this.pushApp(renderApp(queue.prs, queue.count, beep))
    // Only commit state on a delivered push, so a beep isn't "used up" while
    // the device is offline — it fires when the device next reconnects.
    if (status === 200) {
      await this.ctx.storage.put("last_seen", numbers)
      await this.ctx.storage.put("last_push_ms", Date.now())
    }
    console.log(
      `pollAndPush: count=${queue.count} new=${newOnes.length} beep=${beep} ` +
        `relay=${status} reason=${setsDiffer ? "changed" : "heartbeat"}`,
    )
  }
}

// wrangler.jsonc binds the class named "DeviceAgent"; re-exporting our subclass
// under that name keeps the binding + migration unchanged.
export { PRReviewAgent as DeviceAgent }

export default {
  async fetch(request: Request, env: Env) {
    const res = await routeDeviceRequest(request, env.DeviceAgent)
    if (res) return res
    return new Response("Not found", { status: 404 })
  },

  // Cron trigger (every 2 min) → poll the configured device's queue.
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(
      (async () => {
        const agent = await getAgentByName(env.DeviceAgent, env.DEVICE_ID)
        await agent.fetch(
          new Request(`https://do/devices/${env.DEVICE_ID}/poll`, { method: "POST" }),
        )
      })(),
    )
  },
} satisfies ExportedHandler<Env>
