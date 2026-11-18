// NIP-44 v2: versioned encryption for Nostr payloads.
// https://github.com/nostr-protocol/nips/blob/master/44.md
//
// secp256k1 ECDH → HKDF-SHA256 → ChaCha20 + HMAC-SHA256 (encrypt-then-MAC),
// with length-hiding padding. Implemented to the spec's pseudo-code, step for
// step, and verified against the official vector file (paulmillr/nip44,
// sha256 269ed0f6…5040 — the checksum the NIP itself publishes).

import { getSharedSecret } from '../vendor/secp256k1.mjs';
import { b64decode, b64encode, concat, equalConstantTime, fromUtf8, hmacSha256, randomBytes, unhex, utf8 } from './bytes.js';
import { chacha20 } from './chacha20.js';

const VERSION = 2;
const SALT = utf8('nip44-v2');
const EXTENDED_PREFIX_THRESHOLD = 65536;

// The spec allows plaintexts up to 2^32-1 and says implementations SHOULD set
// a lower limit. Signaling messages are a few KB; 65535 also keeps us inside
// the classic (u16-prefix) format every deployed client understands.
export const DEFAULT_MAX_PLAINTEXT = 65535;

/** conversation_key = HKDF-extract(IKM = shared_x, salt = "nip44-v2"). Symmetric: conv(a,B) == conv(b,A). */
export function getConversationKey(secretKey, pubkeyHex) {
  const sk = typeof secretKey === 'string' ? unhex(secretKey) : secretKey;
  const shared = getSharedSecret(sk, unhex('02' + pubkeyHex)); // x-only key → even-y point, per BIP-340
  return hmacSha256(SALT, shared.subarray(1, 33));             // HKDF-extract is HMAC(salt, IKM)
}

/** HKDF-expand(PRK = conversation_key, info = nonce, L = 76), sliced into the three message keys. */
export function getMessageKeys(conversationKey, nonce) {
  if (conversationKey.length !== 32) throw new Error('invalid conversation_key length');
  if (nonce.length !== 32) throw new Error('invalid nonce length');
  let t = new Uint8Array(0);
  const okm = [];
  for (let i = 1; okm.reduce((n, b) => n + b.length, 0) < 76; i++) {
    t = hmacSha256(conversationKey, t, nonce, Uint8Array.of(i));
    okm.push(t);
  }
  const keys = concat(...okm).subarray(0, 76);
  return { chachaKey: keys.slice(0, 32), chachaNonce: keys.slice(32, 44), hmacKey: keys.slice(44, 76) };
}

/** calc_padded_len, with plain Number maths (exact to 2^53, well past the 2^32 the spec needs). */
export function calcPaddedLen(len) {
  if (!Number.isInteger(len) || len < 1) throw new Error('expected positive integer');
  if (len <= 32) return 32;
  let nextPower = 1;
  while (nextPower <= len - 1) nextPower *= 2;       // == 1 << (floor(log2(len - 1)) + 1)
  const chunk = nextPower <= 256 ? 32 : nextPower / 8;
  return chunk * (Math.floor((len - 1) / chunk) + 1);
}

function pad(plaintext, maxLen) {
  const unpadded = utf8(plaintext);
  const len = unpadded.length;
  if (len < 1 || len > maxLen || len > 0xffffffff) throw new Error('invalid plaintext length');
  let prefix;
  if (len >= EXTENDED_PREFIX_THRESHOLD) {
    prefix = new Uint8Array(6);
    new DataView(prefix.buffer).setUint32(2, len);
  } else {
    prefix = new Uint8Array(2);
    new DataView(prefix.buffer).setUint16(0, len);
  }
  return concat(prefix, unpadded, new Uint8Array(calcPaddedLen(len) - len));
}

function unpad(padded) {
  if (padded.length < 2) throw new Error('invalid padding');
  const dv = new DataView(padded.buffer, padded.byteOffset, padded.byteLength);
  let len = dv.getUint16(0);
  let prefixLen = 2;
  if (len === 0) {
    if (padded.length < 6) throw new Error('invalid padding');
    len = dv.getUint32(2);
    if (len < EXTENDED_PREFIX_THRESHOLD) throw new Error('invalid padding');
    prefixLen = 6;
  }
  const unpadded = padded.subarray(prefixLen, prefixLen + len);
  if (len === 0 || unpadded.length !== len || padded.length !== prefixLen + calcPaddedLen(len)) {
    throw new Error('invalid padding');
  }
  return fromUtf8(unpadded);
}

function decodePayload(payload, maxLen) {
  if (typeof payload !== 'string') throw new Error('invalid payload');
  const plen = payload.length;
  if (plen === 0 || payload[0] === '#') throw new Error('unknown encryption version');
  // Size checks happen before any base64 decoding, as the spec asks.
  const maxPayload = Math.ceil((65 + 6 + calcPaddedLen(Math.max(maxLen, 1))) / 3) * 4;
  if (plen < 132 || plen > maxPayload) throw new Error('invalid payload size');
  const data = b64decode(payload);
  const dlen = data.length;
  if (dlen < 99) throw new Error('invalid data size');
  const version = data[0];
  if (version !== VERSION) throw new Error('unknown encryption version ' + version);
  return { nonce: data.subarray(1, 33), ciphertext: data.subarray(33, dlen - 32), mac: data.subarray(dlen - 32) };
}

export function encrypt(plaintext, conversationKey, nonce = randomBytes(32), maxLen = DEFAULT_MAX_PLAINTEXT) {
  const { chachaKey, chachaNonce, hmacKey } = getMessageKeys(conversationKey, nonce);
  const ciphertext = chacha20(chachaKey, chachaNonce, pad(plaintext, maxLen));
  const mac = hmacSha256(hmacKey, nonce, ciphertext); // aad = nonce
  return b64encode(concat(Uint8Array.of(VERSION), nonce, ciphertext, mac));
}

export function decrypt(payload, conversationKey, maxLen = DEFAULT_MAX_PLAINTEXT) {
  const { nonce, ciphertext, mac } = decodePayload(payload, maxLen);
  const { chachaKey, chachaNonce, hmacKey } = getMessageKeys(conversationKey, nonce);
  // MAC first, in constant time; nothing is decrypted unless it verifies.
  if (!equalConstantTime(hmacSha256(hmacKey, nonce, ciphertext), mac)) throw new Error('invalid MAC');
  return unpad(chacha20(chachaKey, chachaNonce, ciphertext));
}
