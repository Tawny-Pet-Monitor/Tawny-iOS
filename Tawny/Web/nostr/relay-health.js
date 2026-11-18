// What each Nostr relay did the last time this device used it.
//
// Nostr has no flag that says "this relay will carry your messages": a relay
// can accept the connection and then refuse every event (a web-of-trust or
// paid relay, or one that drops ephemeral kinds). So the transport tests each
// relay the honest way (it sends itself one sealed message through it and
// waits for it to come back; see transport.js) and the verdict is kept here,
// so the next session skips a relay that refused instead of finding out again.
//
// Kept per device in localStorage, never sent anywhere. Only a refusal is
// remembered as bad: a timeout may be this network, not the relay.

const SLOT = 'tawny.nostrRelayHealth';
const SKIP_FOR_MS = 6 * 60 * 60 * 1000;        // a relay that refused is left out this long
const FORGET_AFTER_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_ENTRIES = 16;
export const VERDICTS = new Set(['ok', 'refused', 'no-echo', 'unreachable', 'testing']);

/** @returns {Record<string, {v: string, why: string, ms: number|null, at: number}>} */
export function readHealth() {
  let raw;
  try { raw = JSON.parse(localStorage.getItem(SLOT) || '{}'); } catch { return {}; }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const now = Date.now();
  const out = {};
  for (const [url, h] of Object.entries(raw)) {
    if (typeof url !== 'string' || url.length > 200 || !h || typeof h !== 'object') continue;
    if (!VERDICTS.has(h.v) || typeof h.at !== 'number' || now - h.at > FORGET_AFTER_MS) continue;
    out[url] = { v: h.v, why: typeof h.why === 'string' ? h.why.slice(0, 120) : '', ms: Number.isFinite(h.ms) ? h.ms : null, at: h.at };
  }
  return out;
}

export function recordHealth(url, v, why = '', ms = null) {
  if (!VERDICTS.has(v) || v === 'testing') return;
  const all = readHealth();
  all[url] = { v, why: String(why).slice(0, 120), ms, at: Date.now() };
  const keep = Object.entries(all).sort((a, b) => b[1].at - a[1].at).slice(0, MAX_ENTRIES);
  try { localStorage.setItem(SLOT, JSON.stringify(Object.fromEntries(keep))); } catch {}
}

/** Whether a stored verdict means "do not dial this relay now". */
const skip = (h, now) => !!h && (h.v === 'refused' || h.v === 'no-echo') && now - h.at < SKIP_FOR_MS;

/**
 * The relays worth dialling, and the ones left out (with why). If every relay
 * is marked bad, all of them are tried anyway: stale knowledge must never
 * leave the user with no Nostr at all.
 */
export function pickRelays(urls) {
  const h = readHealth();
  const now = Date.now();
  const use = urls.filter((u) => !skip(h[u], now));
  if (!use.length) return { use: urls.slice(), skipped: [] };
  return { use, skipped: urls.filter((u) => skip(h[u], now)).map((u) => ({ url: u, why: h[u].why || h[u].v })) };
}
