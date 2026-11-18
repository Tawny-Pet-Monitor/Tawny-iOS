// NIP-59 gift wrap: rumor → seal (kind 13) → wrap (kind 1059, or 21059 ephemeral).
// https://github.com/nostr-protocol/nips/blob/master/59.md
//
//   rumor  the real message, unsigned (deniable if it ever leaks)
//   seal   kind 13, signed by the real sender, tags MUST be empty, rumor
//          NIP-44-encrypted sender → recipient
//   wrap   signed by a one-time random key, only a p tag naming the
//          recipient, seal NIP-44-encrypted one-time key → recipient
//
// A relay therefore learns: "someone sent ~N bytes to <recipient key>". Not who
// sent it, not what kind of message it is, not when it was really written.

import { nowSec, randomInt } from './bytes.js';
import { eventProblem, finalizeEvent, generateSecretKey, getEventHash, getPublicKey, shapeProblem, tagValues } from './nostr.js';
import { decrypt, encrypt, getConversationKey } from './nip44.js';

export const KIND_SEAL = 13;
export const KIND_GIFT_WRAP = 1059;
export const KIND_EPHEMERAL_GIFT_WRAP = 21059;

// NIP-59 says to tweak seal/wrap timestamps and keep them in the past; its
// example goes back up to two days. That is fine for stored kind 1059, but
// strfry — which runs relay.damus.io, nos.lol and most big public relays —
// rejects *ephemeral* events older than 60 s by default
// (rejectEphemeralEventsOlderThanSeconds = 60). So ephemeral wraps get a small
// jitter: enough to decouple the outer timestamps from the real one, never
// enough to be dropped.
export const EPHEMERAL_JITTER_S = 20;
const STORED_JITTER_S = 2 * 24 * 3600;

const jitter = (kind) => randomInt((kind === KIND_EPHEMERAL_GIFT_WRAP ? EPHEMERAL_JITTER_S : STORED_JITTER_S) + 1);

// ECDH is the slow part; a pairing talks to the same one or two keys all the time.
const ckCache = new Map();
function conversationKey(sk, pub) {
  const k = getPublicKey(sk) + pub;
  let ck = ckCache.get(k);
  if (!ck) {
    ck = getConversationKey(sk, pub);
    if (ckCache.size > 256) ckCache.clear();
    ckCache.set(k, ck);
  }
  return ck;
}

export function createRumor({ kind, tags = [], content = '', created_at = nowSec() }, senderPub) {
  const rumor = { kind, created_at, tags, content, pubkey: senderPub };
  rumor.id = getEventHash(rumor);
  return rumor;
}

export function createSeal(rumor, senderSk, recipientPub, wrapKind) {
  return finalizeEvent({
    kind: KIND_SEAL,
    created_at: nowSec() - jitter(wrapKind),
    tags: [],
    content: encrypt(JSON.stringify(rumor), conversationKey(senderSk, recipientPub)),
  }, senderSk);
}

export function createWrap(seal, recipientPub, { kind = KIND_EPHEMERAL_GIFT_WRAP, expiresIn } = {}) {
  const oneTime = generateSecretKey();   // never reused, never stored: discarded after this call
  const tags = [['p', recipientPub]];
  if (expiresIn) tags.push(['expiration', String(nowSec() + expiresIn)]); // NIP-40
  return finalizeEvent({
    kind,
    created_at: nowSec() - jitter(kind),
    tags,
    content: encrypt(JSON.stringify(seal), getConversationKey(oneTime, recipientPub)),
  }, oneTime);
}

/** Wrap a message for one recipient. Returns every layer so the demo can show them. */
export function giftWrap(template, senderSk, recipientPub, opts = {}) {
  const kind = opts.kind ?? KIND_EPHEMERAL_GIFT_WRAP;
  const rumor = createRumor(template, getPublicKey(senderSk));
  const seal = createSeal(rumor, senderSk, recipientPub, kind);
  const wrap = createWrap(seal, recipientPub, { ...opts, kind });
  return { rumor, seal, wrap };
}

export class UnwrapError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

const fail = (code, msg) => { throw new UnwrapError(code, msg); };

function parseJson(text, what) {
  try { return JSON.parse(text); } catch { return fail('bad-json', `${what} is not JSON`); }
}

/**
 * Open a gift wrap addressed to `recipientSk`. Every check NIP-59 and NIP-17
 * call for, in an order that never decrypts anything unauthenticated:
 *  wrap signature → addressed to me → NIP-44 MAC → seal signature → seal tags
 *  empty → NIP-44 MAC → rumor unsigned + id matches → rumor author == seal signer.
 */
export function unwrap(wrap, recipientSk) {
  const me = getPublicKey(recipientSk);
  if (wrap?.kind !== KIND_GIFT_WRAP && wrap?.kind !== KIND_EPHEMERAL_GIFT_WRAP) fail('not-a-wrap', 'not a gift wrap');
  const wp = eventProblem(wrap);
  if (wp) fail('bad-wrap', 'wrap: ' + wp);
  if (!tagValues(wrap, 'p').includes(me)) fail('not-for-me', 'wrap is addressed to someone else');

  let sealJson;
  try { sealJson = decrypt(wrap.content, conversationKey(recipientSk, wrap.pubkey)); }
  catch (e) { fail('decrypt-wrap', 'wrap does not decrypt: ' + e.message); }
  const seal = parseJson(sealJson, 'seal');
  const sp = eventProblem(seal);
  if (sp) fail('bad-seal', 'seal: ' + sp);
  if (seal.kind !== KIND_SEAL) fail('bad-seal', 'seal is not kind 13');
  if (seal.tags.length !== 0) fail('bad-seal', 'seal tags must be empty');

  let rumorJson;
  try { rumorJson = decrypt(seal.content, conversationKey(recipientSk, seal.pubkey)); }
  catch (e) { fail('decrypt-seal', 'seal does not decrypt: ' + e.message); }
  const rumor = parseJson(rumorJson, 'rumor');
  const rp = shapeProblem(rumor, { signed: false });
  if (rp) fail('bad-rumor', 'rumor: ' + rp);
  if ('sig' in rumor) fail('bad-rumor', 'rumor must be unsigned');
  if (getEventHash(rumor) !== rumor.id) fail('bad-rumor', 'rumor id does not match');
  // NIP-17: without this, anyone could seal a rumor that claims another author.
  if (rumor.pubkey !== seal.pubkey) fail('impersonation', 'rumor author is not the seal signer');
  return { seal, rumor };
}
