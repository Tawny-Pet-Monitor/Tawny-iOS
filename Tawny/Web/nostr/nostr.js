// NIP-01 events: build, sign, verify. Same primitives as Tawny's tip.js
// (vendored noble-secp256k1 3.0.0, BIP-340 Schnorr), made strict about shape.
// https://github.com/nostr-protocol/nips/blob/master/01.md

import { hashes, schnorr } from '../vendor/secp256k1.mjs';
import { sha256 } from '../sha256.js';
import { hex, hmacSha256, isHex, nowSec, randomBytes, unhex, utf8 } from './bytes.js';

hashes.sha256 = sha256;
hashes.hmacSha256 = (key, msg) => hmacSha256(key, msg);

export const generateSecretKey = () => schnorr.keygen().secretKey;
export const getPublicKey = (sk) => hex(schnorr.getPublicKey(sk));

/** The NIP-01 serialization whose sha256 is the event id. */
export const serializeEvent = (ev) => JSON.stringify([0, ev.pubkey, ev.created_at, ev.kind, ev.tags, ev.content]);
export const getEventHash = (ev) => hex(sha256(utf8(serializeEvent(ev))));

export function finalizeEvent({ kind, tags = [], content = '', created_at = nowSec() }, sk) {
  const ev = { kind, created_at, tags, content, pubkey: getPublicKey(sk) };
  ev.id = getEventHash(ev);
  ev.sig = hex(schnorr.sign(unhex(ev.id), sk, randomBytes(32)));
  return ev;
}

/** Shape only: field types and lengths exactly as NIP-01 defines them. Says why when it fails. */
export function shapeProblem(ev, { signed = true } = {}) {
  if (!ev || typeof ev !== 'object' || Array.isArray(ev)) return 'not an object';
  if (!isHex(ev.id, 32)) return 'id is not 32-byte lowercase hex';
  if (!isHex(ev.pubkey, 32)) return 'pubkey is not 32-byte lowercase hex';
  if (signed && !isHex(ev.sig, 64)) return 'sig is not 64-byte lowercase hex';
  if (!Number.isInteger(ev.kind) || ev.kind < 0 || ev.kind > 65535) return 'kind out of range';
  if (!Number.isInteger(ev.created_at) || ev.created_at < 0) return 'bad created_at';
  if (typeof ev.content !== 'string') return 'content is not a string';
  if (!Array.isArray(ev.tags) || !ev.tags.every((t) => Array.isArray(t) && t.length > 0 && t.every((x) => typeof x === 'string'))) {
    return 'tags must be arrays of strings';
  }
  return null;
}

/** Why an event fails NIP-01 (shape, id, signature), or null when it is valid. */
export function eventProblem(ev) {
  const shape = shapeProblem(ev);
  if (shape) return shape;
  if (getEventHash(ev) !== ev.id) return 'id does not match content';
  let ok = false;
  try { ok = schnorr.verify(unhex(ev.sig), unhex(ev.id), unhex(ev.pubkey)); } catch { ok = false; }
  return ok ? null : 'bad signature';
}

export const verifyEvent = (ev) => eventProblem(ev) === null;

export const tagValues = (ev, name) => ev.tags.filter((t) => t[0] === name).map((t) => t[1]);
export const tagValue = (ev, name) => tagValues(ev, name)[0];

/** NIP-01 kind ranges: what a relay is supposed to do with each. */
export function kindClass(kind) {
  if (kind === 0 || kind === 3 || (kind >= 10000 && kind < 20000)) return 'replaceable';
  if (kind >= 20000 && kind < 30000) return 'ephemeral';
  if (kind >= 30000 && kind < 40000) return 'addressable';
  return 'regular';
}

/** NIP-40: the expiration timestamp, or null. */
export function expiresAt(ev) {
  const v = tagValue(ev, 'expiration');
  return v !== undefined && /^\d+$/.test(v) ? Number(v) : null;
}

/** NIP-01 filter matching (ids/authors exact, kinds, #<letter>, since/until). */
export function matchFilter(f, ev) {
  if (f.ids && !f.ids.includes(ev.id)) return false;
  if (f.authors && !f.authors.includes(ev.pubkey)) return false;
  if (f.kinds && !f.kinds.includes(ev.kind)) return false;
  if (f.since !== undefined && ev.created_at < f.since) return false;
  if (f.until !== undefined && ev.created_at > f.until) return false;
  for (const key of Object.keys(f)) {
    if (key.length === 2 && key[0] === '#') {
      const want = f[key];
      if (!ev.tags.some((t) => t[0] === key[1] && want.includes(t[1]))) return false;
    }
  }
  return true;
}
