// Byte helpers shared by the browser pages, the relay and the tests.
// Everything here is synchronous and needs nothing but getRandomValues, so it
// works on plain-http pages (no crypto.subtle) exactly as Tawny's own tip.js does.

import { sha256 } from '../sha256.js';

const encoder = new TextEncoder();
const strictDecoder = new TextDecoder('utf-8', { fatal: true });

export const utf8 = (s) => encoder.encode(s);
/** UTF-8 decode that throws on malformed input instead of inserting U+FFFD. */
export const fromUtf8 = (b) => strictDecoder.decode(b);

export const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

export function unhex(s) {
  if (typeof s !== 'string' || s.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(s)) throw new Error('invalid hex');
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return out;
}

/** Lowercase hex of exactly `bytes` bytes — the only form NIP-01 allows for ids, keys and sigs. */
export const isHex = (s, bytes) => typeof s === 'string' && s.length === bytes * 2 && /^[0-9a-f]+$/.test(s);

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

export const randomBytes = (n) => crypto.getRandomValues(new Uint8Array(n));

/** Uniform integer in [0, max). Rejection sampling, so no modulo bias. */
export function randomInt(max) {
  if (!Number.isInteger(max) || max <= 0 || max > 2 ** 32) throw new Error('bad range');
  const limit = Math.floor(2 ** 32 / max) * max;
  const buf = new Uint32Array(1);
  for (;;) {
    crypto.getRandomValues(buf);
    if (buf[0] < limit) return buf[0] % max;
  }
}

/** HMAC-SHA256 (RFC 2104) over the concatenation of `msgs`. */
export function hmacSha256(key, ...msgs) {
  const B = 64;
  let k = key.length > B ? sha256(key) : key;
  const block = new Uint8Array(B);
  block.set(k);
  const ipad = block.map((x) => x ^ 0x36);
  const opad = block.map((x) => x ^ 0x5c);
  return sha256(concat(opad, sha256(concat(ipad, ...msgs))));
}

/** Compare without an early exit, so timing does not reveal where two MACs differ. */
export function equalConstantTime(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export function b64encode(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

// RFC 4648 with padding, nothing else: atob() alone forgives whitespace and
// missing padding, and NIP-44 wants malformed payloads rejected outright.
const B64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

export function b64decode(str) {
  if (typeof str !== 'string' || !B64.test(str)) throw new Error('invalid base64');
  const s = atob(str);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export const b64urlEncode = (bytes) => b64encode(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
export function b64urlDecode(str) {
  if (typeof str !== 'string' || !/^[A-Za-z0-9_-]*$/.test(str)) throw new Error('invalid base64url');
  const s = str.replace(/-/g, '+').replace(/_/g, '/');
  return b64decode(s + '='.repeat((4 - (s.length % 4)) % 4));
}

export const nowSec = () => Math.floor(Date.now() / 1000);
