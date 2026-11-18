// One relay, one honest answer: can this device pass a Tawny envelope through it?
//
// The same test the transport runs when a call starts (transport.js, #probe),
// as a stand-alone function for the screens that ask before a call: the Tawny
// server page, and the "only my relays" check. It sends one sealed envelope
// addressed to a throwaway key of its own through that relay alone and waits
// for it to come back. "It connected" is not an answer; "it delivered" is.

import { generateSecretKey, getPublicKey } from './nostr.js';
import { giftWrap, KIND_EPHEMERAL_GIFT_WRAP } from './nip59.js';
import { Relay } from './relay-client.js';

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * @param {string} url  ws:// or wss://
 * @returns {Promise<{ok: true, ms: number} | {ok: false, why: 'connect'|'refused'|'listen'|'silent', detail: string}>}
 */
export async function testRelay(url) {
  const sk = generateSecretKey();
  const me = getPublicKey(sk);
  let relay;
  try { relay = new Relay(url, { authKey: sk }); } catch { return { ok: false, why: 'connect', detail: '' }; }
  try {
    try {
      await Promise.race([relay.connect(), new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 8000))]);
    } catch { return { ok: false, why: 'connect', detail: '' }; }
    await wait(300);
    if (relay.challenge && !relay.authedAs) await relay.whenAuthed(3000);
    const back = new Promise((resolve) => {
      relay.subscribe([{ kinds: [KIND_EPHEMERAL_GIFT_WRAP], '#p': [me] }], {
        onEvent: () => resolve(Date.now()),
        // A relay that wants a sign-in first closes the subscription once and
        // the client retries by itself; anything else is a real refusal.
        onClosed: (w) => resolve('closed: ' + String(w || '').slice(0, 80)),
      });
      setTimeout(() => resolve(null), 6000);
    });
    await wait(400);
    // About 11 KB on the wire, the size of a real answer.
    const { wrap } = giftWrap({ kind: 25050, tags: [['p', me], ['t', 'ping']], content: JSON.stringify({ pad: 'x'.repeat(6000) }) },
      sk, me, { kind: KIND_EPHEMERAL_GIFT_WRAP, expiresIn: 120 });
    const sent = Date.now();
    const res = await relay.publish(wrap);
    if (!res.ok) return { ok: false, why: 'refused', detail: String(res.message || '').slice(0, 80) };
    const at = await back;
    if (typeof at === 'number') return { ok: true, ms: at - sent };
    return at ? { ok: false, why: 'listen', detail: at } : { ok: false, why: 'silent', detail: '' };
  } catch (e) {
    return { ok: false, why: 'connect', detail: String(e && e.message || e).slice(0, 80) };
  } finally { try { relay.close(); } catch {} }
}

/** Test several relays at once; results in the same order. */
export const testRelays = (urls) => Promise.all(urls.map((u) => testRelay(u)));
