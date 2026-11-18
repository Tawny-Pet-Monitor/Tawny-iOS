// ChaCha20 stream cipher, RFC 8439 §2.3–2.4 (96-bit nonce, 32-bit block counter).
// NIP-44 v2 uses it with the counter starting at 0. WebCrypto has no ChaCha20,
// hence this; it is checked against the RFC's own vector and every NIP-44 v2
// vector in test/.

const SIGMA = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]; // "expand 32-byte k"

const rotl = (x, n) => (x << n) | (x >>> (32 - n));

function quarter(s, a, b, c, d) {
  s[a] = (s[a] + s[b]) | 0; s[d] = rotl(s[d] ^ s[a], 16);
  s[c] = (s[c] + s[d]) | 0; s[b] = rotl(s[b] ^ s[c], 12);
  s[a] = (s[a] + s[b]) | 0; s[d] = rotl(s[d] ^ s[a], 8);
  s[c] = (s[c] + s[d]) | 0; s[b] = rotl(s[b] ^ s[c], 7);
}

const le32 = (b, i) => (b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)) >>> 0;

function block(init, out) {
  const s = Int32Array.from(init);
  for (let i = 0; i < 10; i++) {
    quarter(s, 0, 4, 8, 12); quarter(s, 1, 5, 9, 13); quarter(s, 2, 6, 10, 14); quarter(s, 3, 7, 11, 15);
    quarter(s, 0, 5, 10, 15); quarter(s, 1, 6, 11, 12); quarter(s, 2, 7, 8, 13); quarter(s, 3, 4, 9, 14);
  }
  for (let i = 0; i < 16; i++) {
    const w = (s[i] + init[i]) | 0;
    out[i * 4] = w; out[i * 4 + 1] = w >>> 8; out[i * 4 + 2] = w >>> 16; out[i * 4 + 3] = w >>> 24;
  }
}

/** XOR `data` with the ChaCha20 keystream. Encryption and decryption are the same call. */
export function chacha20(key, nonce, data, counter = 0) {
  if (!(key instanceof Uint8Array) || key.length !== 32) throw new Error('chacha20: key must be 32 bytes');
  if (!(nonce instanceof Uint8Array) || nonce.length !== 12) throw new Error('chacha20: nonce must be 12 bytes');
  const blocks = Math.ceil(data.length / 64);
  if (counter + blocks > 2 ** 32) throw new Error('chacha20: counter overflow');
  const init = new Int32Array(16);
  for (let i = 0; i < 4; i++) init[i] = SIGMA[i];
  for (let i = 0; i < 8; i++) init[4 + i] = le32(key, i * 4);
  for (let i = 0; i < 3; i++) init[13 + i] = le32(nonce, i * 4);
  const out = new Uint8Array(data.length);
  const ks = new Uint8Array(64);
  for (let off = 0; off < data.length; off += 64) {
    init[12] = counter++;
    block(init, ks);
    const n = Math.min(64, data.length - off);
    for (let i = 0; i < n; i++) out[off + i] = data[off + i] ^ ks[i];
  }
  return out;
}
