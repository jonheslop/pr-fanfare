# PR-Review Beeper

Turns the M5StickS3 into a physical indicator of your GitHub review queue:
shows how many PRs are waiting on your review, lets you cycle through them with
the buttons, and **beeps when a new one arrives**.

![A picture of the Stick in action](https://imagedelivery.net/tfgleCjJafHVtd2F4ngDnQ/bfb17bb8-3996-4694-5624-d6be15423200/large)

## How it works

A Cloudflare cron fires every 2 minutes. The worker queries the GitHub search
API for `review-requested:@me`, diffs the result against the last-seen set
(stored in a Durable Object), and — when the set changes, or on a ~10-minute
heartbeat — **POSTs a small Lua app to the relay the device is connected to**
(the hosted `resident.inanimate.tech`). A genuinely new PR sets a beep flag the
device obeys on load. The device only ever receives the standard
`{type:"app",code}` message.

The device stays on the hosted relay rather than connecting to this worker
directly: the firmware's WebSocket TLS only trusts the Google Trust Services
root, and `*.workers.dev` certs are issued by Let's Encrypt — so a device
pointed at the worker fails the handshake (`-0x2700`). Pushing through the
hosted relay (a GTS-rooted cert it already trusts) sidesteps that entirely. The
Durable Object here is just a scheduler + state store; no device connects to it.

```
cron (*/2 * * * *) → scheduled() → DO /poll
   → GitHub search review-requested:@me
   → diff vs last_seen (DO storage)
   → if changed or heartbeat stale:
        POST {type:app,code} → RELAY_BASE/devices/<id>/send   (beep if new)
device (on resident.inanimate.tech): count + button-cyclable list; BTN0 next, BTN1 prev
```

`last_seen` / `last_push_ms` only advance on a **delivered** (HTTP 200) push, so
while the device is offline the worker keeps retrying each poll and the beep
isn't "used up" — it fires when the device next reconnects.

## Files

| File | Role |
| --- | --- |
| `src/worker.ts` | `PRReviewAgent` — poll, diff, render, push-to-relay; cron `scheduled()` |
| `device-apps/pr-review.lua` | The display/beep/cycle app (imported into the worker as text) |
| `src/bindings.d.ts` | Types for the `*.lua` text import and the `GITHUB_TOKEN` / `DEVICE_ID` / `RELAY_BASE` bindings |
| `wrangler.jsonc` | Adds the `*/2` cron trigger, the `Text` rule, and `DEVICE_ID` / `RELAY_BASE` vars |

`DEVICE_ID` (`{ID}`) and `RELAY_BASE` (`https://resident.inanimate.tech`)
are set in `wrangler.jsonc`. Point `RELAY_BASE` at a different relay only if your
device connects somewhere else.

## Setup (the steps that need you)

These need your Cloudflare account, a GitHub token, and the physical device — I
can't do them from here.

### 1. GitHub token

Create a token that can read the repos whose PRs you review:

- **Fine-grained PAT:** Pull requests → Read-only on the relevant repos/orgs.
- **or classic PAT:** `repo` scope (needed to see private-repo PRs).

`review-requested:@me` resolves to the token owner, so no username is needed.

### 2. Deploy the worker

```bash
cd server-template
npm install
npx wrangler secret put GITHUB_TOKEN     # paste the token
npx wrangler deploy
```

Wrangler prints a URL like `resident-server-template.<account>.workers.dev`.

> Local smoke test (optional): put the token in `.dev.vars` as
> `GITHUB_TOKEN=...`, run `npx wrangler dev`, then
> `curl -X POST http://localhost:8787/devices/{ID}/poll` and watch the logs
> for `pollAndPush: count=… new=… beep=…`.

### 3. Keep the device on the hosted relay

The device connects to `resident.inanimate.tech` (the firmware default) — the
worker pushes there, so no custom firmware host is needed. `RESIDENT_HOST` in
`main.cpp` should be:

```cpp
static constexpr const char* RESIDENT_HOST = "resident.inanimate.tech";
```

Only reflash if the device is currently pointed somewhere else (e.g. you tried a
`*.workers.dev` host and hit the `-0x2700` TLS error). Build from a complete
firmware tree — the `symlink://../../..` resident lib dep only resolves from the
repo's own `examples/m5stick-demo/device`, not a copied-out folder:

```bash
cd <resident-repo>/examples/m5stick-demo/device
pio run -e m5sticks3 -t upload
```

### 4. Done

The device sits on the hosted relay showing its device-ID screen. Within ~2 min
the cron pushes the current queue (ALL CLEAR if empty), and from then on it
repaints + beeps within ~2 min of a new review request. A reboot repaints within
~10 min (the heartbeat) — or sooner if the queue changes. No manual app push is
needed; the worker owns the app.

## Verify end-to-end

- Count on screen matches your GitHub review queue.
- Have someone request your review on a PR → device beeps within ~2 min and the
  PR appears in the cyclable list (BTN0 next, BTN1 prev).
- Review/close it → count drops on the next poll, with **no** spurious beep.

## Testing with curl

Work outward from "no deploy needed" to the full loop. Fastest sanity path:
**A → B `/preview` → deploy + `wrangler tail`.**

### A. The GitHub side by itself — confirms the token + your real queue

No worker involved; this is exactly what `fetchReviewQueue()` sees.

```bash
export GITHUB_TOKEN=ghp_xxx
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
     -H "Accept: application/vnd.github+json" \
     -H "User-Agent: resident-pr-review" \
     "https://api.github.com/search/issues?q=is%3Aopen+is%3Apull-request+review-requested%3A%40me+archived%3Afalse&per_page=20" \
  | jq '{count: .total_count, prs: [.items[] | {n:.number, t:.title, repo:(.repository_url|split("/repos/")[1])}]}'
```

### B. The worker locally (`wrangler dev`) — fetch + render, no device needed

```bash
cd server-template
echo "GITHUB_TOKEN=ghp_xxx" > .dev.vars        # gitignored
npx wrangler dev                               # http://localhost:8787
```

In another terminal:

```bash
curl localhost:8787/                           # -> "Resident relay"
curl localhost:8787/devices/{ID}           # -> deviceId + connections: 0

# The ACTUAL Lua it would push, with your real PRs baked in (stateless):
curl localhost:8787/devices/{ID}/preview

# Run the real poll path; watch the wrangler dev console for:
#   pollAndPush: count=… new=… beep=… sent=0
curl -X POST localhost:8787/devices/{ID}/poll   # -> "polled"
```

- `sent=0` is expected locally — no device is connected to the dev worker;
  you're testing fetch → diff → render.
- `/poll` only logs/pushes **when the set changed** (the first call always
  does). For repeatable inspection use `/preview`, which is stateless and never
  writes storage.
- `/preview` returning `github fetch failed: …` means the token is the problem;
  the body carries GitHub's error.

### C. The device push path — independent of GitHub

Confirms the device receives and renders pushed apps. Until you reflash, the
device is on the hosted relay, so target that (swap in your worker URL after
reflashing):

```bash
curl -X POST https://resident.inanimate.tech/devices/{ID}/send \
  -H 'Content-Type: application/json' \
  -d '{"type":"app","code":"function init() screen.clear() screen.text(10,10,\"PUSH OK\",3) screen.flip() end"}'
```

`200` + the screen changes = push path works. `503` = device not connected.

### D. After deploy + reflash — the full loop

```bash
npx wrangler deploy
npx wrangler tail                              # stream the deployed worker's logs
```

The device connecting auto-paints the queue (via `onConnect`). Force a check on
demand and watch `wrangler tail` for the `pollAndPush:` line:

```bash
curl -X POST https://<your-worker>/devices/{ID}/poll
```

## Tuning

- **Poll interval:** edit `triggers.crons` in `wrangler.jsonc` (min 1 min).
- **Scope:** narrow the query in `fetchReviewQueue()` (`src/worker.ts`), e.g. add
  `org:NAME` to the `q` string.
- **Age window:** `MAX_AGE_DAYS` (`src/worker.ts`) drops PRs created more than N
  days ago via a `created:>=` search qualifier — currently 10. Set higher to
  include older PRs, or swap `created:` for `updated:` to key off last activity
  (stale PRs) instead of creation date.
- **List length:** `pr-review.lua` cycles the PRs the worker sends
  (`items.slice(0, 12)` in `renderApp`); the header count is always the true
  total, with "+N more" when it exceeds the visible list.

## Not included (possible upgrades)

- Instant beeps via GitHub webhooks (needs repo/org webhook admin + a secret).
- `team-review-requested:ORG/TEAM` PRs (the query only covers direct requests).
