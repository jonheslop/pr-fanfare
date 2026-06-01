// Imported Lua app bodies (wrangler "Text" rule) arrive as a default string.
declare module "*.lua" {
  const content: string
  export default content
}

// Bindings this worker reads. DEVICE_ID is a plain var (also picked up by
// `wrangler types`); GITHUB_TOKEN is a secret set via `wrangler secret put`.
interface Env {
  GITHUB_TOKEN: string
  DEVICE_ID: string
  // Relay the device is connected to; defaults to the hosted resident relay.
  RELAY_BASE?: string
}
