// Tawny signaling over Nostr, shaped like the room relay app.js already knows.
//
// openSignal() dials either a WebSocket to a Tawny relay or, for tag 'nostr',
// one of these. To app.js it looks the same: it opens, says `welcome`,
// announces `peer-joined` / `peer-left`, and delivers the addressed frames
// (offer, answer, ice, ...) with `from` filled in. Underneath, every frame is a
// NIP-59 ephemeral gift wrap (kind 21059 → seal 13 → rumor 25050) published to
// ordinary Nostr relays, which never see anything but sealed envelopes.
//
// Keys
//   Monitor   random, made once per channel and kept on the Monitor. Only its
//             public half ever leaves: in the pairing link (`np`), and from the
//             Monitor itself to a phone it has let in. Nothing in a QR can open
//             what phones send the Monitor, or speak as the Monitor.
//   Handheld  random, made once per channel and kept in localStorage. It
//             must be told the Monitor's public key (o.stationPub).
//
// Membership (what the room relay's ticket check used to do)
//   A Handheld sends `join` with HMAC(channel key, its key | Monitor key | time).
//   The Monitor answers `here` and lists it as a member; from then on only
//   members' sealed frames are delivered. A Handheld only accepts frames
//   sealed by the Monitor's key. Every message must be fresh (90 s) and is
//   handled once. app.js's own gate (pair code / known phone) still runs on
//   top of this, unchanged.
//
// Presence
//   A Handheld sends `join` every 3 s until its Monitor answers, then every
//   15 s; the Monitor answers each one. A member silent for 50 s is reported as
//   `peer-left`; `leave` says it at once. Ephemeral events are never stored, so
//   a `join` sent while the Monitor was offline is simply gone; the retries
//   cover that, and a Monitor coming up says `here` to the phones it already
//   knows instead of waiting to be asked.
//
// Which relays (relay-health.js)
//   A relay can accept the connection and still refuse or drop every event.
//   So each one is tested as it connects: this device sends itself one sealed
//   envelope, the size of a real answer, through that relay alone, and the
//   relay is used only once it comes back. One that refuses (or accepts and
//   never delivers) is closed for this session and skipped by the next ones
//   for a while; Monitor and Handheld test the same list each on their own,
//   and every frame goes to every relay that passed, so they meet on any
//   relay that works for both.

import { equalConstantTime, hex, hmacSha256, isHex, nowSec, randomBytes, unhex, utf8 } from './bytes.js';
import { generateSecretKey, getPublicKey, tagValue, tagValues } from './nostr.js';
import { giftWrap, KIND_EPHEMERAL_GIFT_WRAP, unwrap, UnwrapError } from './nip59.js';
import { Relay } from './relay-client.js';
import { pickRelays, recordHealth } from './relay-health.js';

export const KIND_SIGNAL = 25050;
// The frames a room relay forwards; same list as rendezvous/protocol.js RELAY.
const RELAYED = new Set(['offer', 'answer', 'ice', 'bye', 'chime', 'chime-ack', 'talking',
  'cameras', 'meta', 'camera-control', 'torch', 'battery']);
const CONTROL = new Set(['join', 'here', 'leave', 'sig']);
// What each side may be told. A Monitor never takes `here`, a Handheld never `join`.
const ACCEPTS = { station: new Set(['join', 'leave', 'sig']), viewer: new Set(['here', 'leave', 'sig']) };
const MAX_SEEN = 4000;             // envelope ids remembered for replay checks; oldest go first
const FLOOD_WINDOW_MS = 10000;
const FLOOD_MAX = 300;             // envelopes per relay per window before the rest are dropped unread
const HEARTBEAT_MS = 15000;
const SEEK_MS = 3000;              // a Handheld that has not found its Monitor yet asks this often
const MAX_REMEMBERED = 8;
const PEER_TIMEOUT_MS = 50000;
const FRESH_PAST_S = 90;
const FRESH_FUTURE_S = 30;
const SEEN_TTL_MS = 5 * 60 * 1000;
const ICE_BATCH_MS = 150;
const WRAP_EXPIRY_S = 120;
const MAX_FRAMES = 40;
const PROBE_TIMEOUT_MS = 5000;     // a relay whose test envelope is not back by now is not used
const PROBE_PAD = 6000;            // makes the test envelope ~11 KB, the size of a real answer
// A refusal that says nothing about the relay's rules: the network, a busy
// relay, a duplicate. Not held against it.
const TRANSIENT = /^(timeout$|not connected$|rate-limited:|duplicate:|error:)/;

const joinProof = (channelKey, handheld, station, at) =>
  hex(hmacSha256(utf8(channelKey), utf8(`tawny-nostr-join-v1|${handheld}|${station}|${at}`)));

/** A secret key kept in localStorage under `slot`, made on first use. */
function storedSecret(slot) {
  let v = null;
  try { v = localStorage.getItem(slot); } catch {}
  if (isHex(v || '', 32)) return unhex(v);
  const sk = generateSecretKey();
  try { localStorage.setItem(slot, hex(sk)); } catch {}
  return sk;
}

const handheldSecret = (roomId) => storedSecret(`tawny.nostrKey.${roomId}`);
// Its own slot, so a device that has been both ends of a channel never uses
// one key for both.
const stationSecret = (name) => storedSecret(`tawny.nostrStationKey.${name}`);

/**
 * The public half of this device's Monitor key for a channel, for the pairing
 * link. `name` is whatever the caller names the channel by on this device; the
 * same name must be given to NostrSocket as `stationKeyName`.
 */
export function stationPublicKey(name) {
  return getPublicKey(stationSecret(name));
}

/** A Monitor public key as it travels in a link or a frame: 64 hex characters. */
export const isStationPub = (v) => typeof v === 'string' && isHex(v, 32);

export class NostrSocket {
  /**
   * @param {object} o
   * @param {string} o.channelKey   the pairing's channel key (never leaves the device)
   * @param {'station'|'viewer'} o.role
   * @param {string} o.roomId       only names this device's stored key
   * @param {string} [o.stationKeyName]  Monitor: names its stored key (default: roomId)
   * @param {string} [o.stationPub]  Handheld: the Monitor's public key, from the pairing
   *                                 link or from the Monitor itself. Required.
   * @param {string[]} o.relays     ws:// or wss:// Nostr relay URLs
   * @param {string} [o.mirror]     DevOps only: URL that receives a copy of every opened layer
   * @param {string} [o.label]      DevOps only: names this connection to the inspector
   * @param {(line: string) => void} [o.log]
   */
  constructor({ channelKey, role, roomId, relays, stationKeyName = '', stationPub = '', mirror = '', label = '', log = () => {} }) {
    if (role !== 'station' && !isStationPub(stationPub)) throw new Error('a Handheld needs the Monitor\'s public key');
    this.readyState = 0;
    this.onopen = null; this.onmessage = null; this.onclose = null; this.onerror = null;
    this.onrelays = null;            // (report) => void: a relay's verdict changed
    this.channelKey = channelKey;
    this.role = role;
    this.sk = role === 'station' ? stationSecret(stationKeyName || roomId) : handheldSecret(roomId);
    this.stationPub = role === 'station' ? getPublicKey(this.sk) : stationPub.toLowerCase();
    this.peersSlot = `tawny.nostrPeers.${roomId}`;
    this.me = getPublicKey(this.sk);
    // Changes every time this socket is made. The keys are stable, so without
    // it a peer that restarted would look like one that never left, and the
    // other side would never be told to call it again.
    this.session = hex(randomBytes(8));
    this.mirrorUrl = mirror;
    this.log = log;
    this.members = new Map();         // pubkey → { role, lastSeen }
    this.outbox = new Map();          // pubkey → { frames, timer }
    this.seenWraps = new Map();
    this.seenRumors = new Map();
    this.timers = [];
    const who = mirror && label ? `?who=${encodeURIComponent(label)}` : '';
    const { use, skipped } = pickRelays(relays);
    for (const s of skipped) this.log(`nostr: skipping ${s.url}, it refused last time (${s.why})`);
    this.relays = use.map((url) => {
      const r = new Relay(url + who, { authUrl: url, authKey: this.sk, log: (lvl, m) => this.log(`nostr ${lvl}: ${m}`) });
      r.verdict = 'testing';            // → 'ok' | 'refused' | 'no-echo' | 'unreachable'
      return r;
    });
    this.skipped = skipped;
    this.#start();
  }

  // ---- what app.js sees ---------------------------------------------------------------------

  #emit(obj) {
    if (this.readyState !== 1) return;
    try { this.onmessage?.({ data: JSON.stringify(obj) }); } catch (e) { this.log('nostr handler threw: ' + e.message); }
  }

  /** How many relays are connected and not known to refuse us (app.js uses it to stop waiting on dead ones). */
  relaysUp() {
    return this.relays.filter((r) => r.verdict !== 'refused' && r.verdict !== 'no-echo' &&
      (r.state === 'open' || r.state === 'authenticating' || r.state === 'authenticated')).length;
  }

  /** Each relay's verdict this session, for Diagnostics and the Servers screens. */
  relayReport() {
    return [
      ...this.relays.map((r) => ({ url: r.authUrl, v: r.verdict, why: r.verdictWhy || '', ms: r.verdictMs ?? null })),
      ...this.skipped.map((s) => ({ url: s.url, v: 'skipped', why: s.why, ms: null })),
    ];
  }

  send(text) {
    if (this.readyState !== 1) return;
    let obj;
    try { obj = JSON.parse(text); } catch { return; }
    if (!obj || !RELAYED.has(obj.type) || typeof obj.to !== 'string') return;
    const to = obj.to;
    if (!this.members.has(to)) return this.log(`nostr: dropped ${obj.type} to non-member ${to.slice(0, 8)}`);
    delete obj.to;
    let box = this.outbox.get(to);
    if (!box) { box = { frames: [], timer: null }; this.outbox.set(to, box); }
    box.frames.push(obj);
    // Trickle ICE comes one candidate at a time; batch it so a call is a
    // handful of envelopes, not forty. Anything else goes out at once, behind
    // whatever was queued, so order is kept.
    if (obj.type !== 'ice' || box.frames.length >= MAX_FRAMES) this.#flush(to);
    else if (!box.timer) box.timer = setTimeout(() => this.#flush(to), ICE_BATCH_MS);
  }

  close(code = 1000, reason = '') {
    if (this.readyState === 3) return;
    for (const pub of this.members.keys()) this.#wrapTo(pub, 'leave', {});
    this.readyState = 3;
    for (const t of this.timers) clearInterval(t);
    for (const box of this.outbox.values()) clearTimeout(box.timer);
    setTimeout(() => { for (const r of this.relays) r.close(); }, 300);   // let the leaves go out
    try { this.onclose?.({ code, reason }); } catch {}
  }

  // ---- lifecycle -------------------------------------------------------------------------------

  async #start() {
    this.#mirror({ t: 'peer', role: this.role === 'station' ? 'monitor' : 'handheld', pub: this.me, mon: this.stationPub });
    // Open as soon as one relay has passed its test, or once every relay has
    // failed (then app.js sees relaysUp() === 0 and moves on at once), or
    // after 6 s whatever happened.
    await new Promise((res) => {
      let done = false;
      const finish = () => { if (!done) { done = true; res(); } };
      const settled = () => {
        if (this.relays.some((r) => r.verdict === 'ok')) finish();
        else if (this.relays.every((r) => r.verdict !== 'testing')) finish();
      };
      for (const r of this.relays) {
        r.subscribe([{ kinds: [KIND_EPHEMERAL_GIFT_WRAP], '#p': [this.me] }], {
          onEvent: (ev) => this.#receive(ev, r),
          onClosed: (why) => {
            this.log(`nostr: ${r.url} closed our subscription: ${why}`);
            this.#judge(r, 'refused', `subscription closed: ${why}`);
            settled();
          },
        });
        r.onState((s) => { if (s === 'open') this.#probe(r, settled); });
        r.connect().catch(() => {
          this.log(`nostr: cannot reach ${r.authUrl}`);
          // Not remembered: it may be this network. It keeps retrying, and is
          // tested if it ever connects.
          if (r.verdict === 'testing') { r.verdict = 'unreachable'; r.verdictWhy = 'cannot connect'; settled(); }
        });
      }
      if (!this.relays.length) finish();
      setTimeout(finish, 6000);
    });
    if (this.readyState !== 0) return;
    this.readyState = 1;
    this.log(`nostr open as ${this.role} ${this.me.slice(0, 12)}… on ${this.relays.length} relay(s)`);
    try { this.onopen?.({}); } catch {}
    this.#emit({ type: 'welcome', id: this.me, peers: [] });
    if (this.role === 'viewer') {
      let last = 0;
      this.#join();
      this.timers.push(setInterval(() => {
        const found = this.members.has(this.stationPub);
        if (Date.now() - last >= (found ? HEARTBEAT_MS : SEEK_MS)) { last = Date.now(); this.#join(); }
      }, 1000));
    } else {
      for (const pub of this.#remembered()) this.#wrapTo(pub, 'here', { s: this.session });
    }
    this.timers.push(setInterval(() => this.#sweep(), 5000));
  }

  // ---- relay test ------------------------------------------------------------------------------

  /**
   * Once per relay per session: publish one sealed envelope to ourselves
   * through this relay only and wait for it to come back on our subscription.
   * If the relay asks for NIP-42 AUTH first, the test waits for that.
   */
  async #probe(r, settled) {
    if (r.verdict === 'unreachable') r.verdict = 'testing';    // it connected after all
    if (r.verdict !== 'testing' || r.probing || this.readyState === 3) return;
    r.probing = true;
    await new Promise((res) => setTimeout(res, 300));          // room for an AUTH challenge to arrive
    if (r.challenge && !r.authedAs) await r.whenAuthed(3000);
    if (this.readyState === 3 || r.state === 'closed') { r.probing = false; return; }
    let wrap;
    try {
      ({ wrap } = giftWrap({ kind: KIND_SIGNAL, tags: [['p', this.me], ['t', 'ping']],
        content: JSON.stringify({ n: hex(randomBytes(8)), pad: 'x'.repeat(PROBE_PAD) }) },
      this.sk, this.me, { kind: KIND_EPHEMERAL_GIFT_WRAP, expiresIn: WRAP_EXPIRY_S }));
    } catch (e) { r.probing = false; return this.log('nostr: could not build the relay test: ' + e.message); }
    r.probeId = wrap.id;
    r.probeAt = Date.now();
    r.probeDone = () => { r.probing = false; settled(); };
    const timer = setTimeout(() => {
      if (r.verdict !== 'testing') return;
      this.#judge(r, 'no-echo', 'accepted the test message but never delivered it');
      r.probeDone();
    }, PROBE_TIMEOUT_MS);
    const res = await r.publish(wrap);
    if (res.ok || r.verdict !== 'testing') return;
    clearTimeout(timer);
    if (TRANSIENT.test(res.message)) {
      // The network, not the relay's rules: test again on the next connect.
      r.verdictWhy = res.message;
      r.probing = false;
      return;
    }
    this.#judge(r, 'refused', res.message || 'refused the test message');
    r.probeDone();
  }

  /** Settle a relay's verdict. A relay that fails is closed for this session. */
  #judge(r, v, why = '', ms = null) {
    if (r.verdict === v || (r.verdict !== 'testing' && v === 'ok')) return;
    if (r.verdict === 'refused' || r.verdict === 'no-echo') return;
    r.verdict = v; r.verdictWhy = why; r.verdictMs = ms;
    recordHealth(r.authUrl, v, why, ms);
    if (v === 'ok') this.log(`nostr: ${r.authUrl} works (${ms} ms round trip)`);
    else {
      this.log(`nostr: not using ${r.authUrl}: ${why}`);
      r.close();
    }
    this.#mirror({ t: 'relay', url: r.authUrl, verdict: v, why, ms });
    this.onrelays?.(this.relayReport());
  }

  #join() {
    const at = nowSec();
    this.#wrapTo(this.stationPub, 'join', { proof: joinProof(this.channelKey, this.me, this.stationPub, at), s: this.session }, at);
  }

  #sweep() {
    const now = Date.now();
    for (const [pub, m] of this.members) {
      if (now - m.lastSeen > PEER_TIMEOUT_MS) {
        this.members.delete(pub);
        this.log(`nostr: ${m.role} ${pub.slice(0, 8)} went quiet`);
        this.#emit({ type: 'peer-left', id: pub });
      }
    }
    for (const map of [this.seenWraps, this.seenRumors]) for (const [k, exp] of map) if (exp < now) map.delete(k);
  }

  // ---- sending --------------------------------------------------------------------------------

  #flush(to) {
    const box = this.outbox.get(to);
    if (!box) return;
    clearTimeout(box.timer);
    box.timer = null;
    const frames = box.frames.splice(0, MAX_FRAMES);
    if (frames.length) this.#wrapTo(to, 'sig', { f: frames });
    if (box.frames.length) this.#flush(to);
  }

  #wrapTo(to, type, body, createdAt = nowSec()) {
    let layers;
    // `n`: a random nonce. A rumor's id is the hash of its contents, so two
    // identical frames written in the same second (two "talking" presses) had
    // the same id and the second was dropped as a replay. Receivers ignore it.
    const content = JSON.stringify({ ...body, n: hex(randomBytes(8)) });
    try {
      layers = giftWrap({ kind: KIND_SIGNAL, created_at: createdAt, tags: [['p', to], ['t', type]], content },
        this.sk, to, { kind: KIND_EPHEMERAL_GIFT_WRAP, expiresIn: WRAP_EXPIRY_S });
    } catch (e) { return this.log('nostr: could not wrap: ' + e.message); }
    const what = type === 'sig' ? body.f.map((f) => f.type).join('+') : type;
    for (const r of this.relays) {
      if (r.verdict === 'refused' || r.verdict === 'no-echo') continue;
      r.publish(layers.wrap).then((res) => {
        if (res.ok) return;
        this.log(`nostr: ${r.authUrl} refused ${what}: ${res.message}`);
        if (!TRANSIENT.test(res.message) && !/^auth-required:/.test(res.message)) this.#judge(r, 'refused', res.message);
      });
    }
    this.#mirror({ t: 'sent', wrapId: layers.wrap.id, type: what, to, seal: layers.seal, rumor: layers.rumor });
  }

  // ---- receiving ------------------------------------------------------------------------------

  #reject(code, reason, wrap, from) {
    this.log(`nostr: refused ${code}: ${reason}`);
    this.#mirror({ t: 'rejected', wrapId: wrap?.id, code, reason, from });
  }

  #receive(wrap, relay) {
    if (this.readyState === 3) return;
    // Our own relay test coming back: this relay carries our envelopes.
    if (relay && relay.probeId && wrap.id === relay.probeId) {
      relay.probeId = null;
      this.#judge(relay, 'ok', '', Date.now() - relay.probeAt);
      relay.probeDone?.();
      return;
    }
    // Flooding a known key costs us a signature check and an ECDH per envelope;
    // past a sane rate, a relay's extra envelopes are dropped without opening.
    if (relay) {
      const now = Date.now();
      if (!relay.flood || now - relay.flood.start > FLOOD_WINDOW_MS) relay.flood = { start: now, n: 0, warned: false };
      if (++relay.flood.n > FLOOD_MAX) {
        if (!relay.flood.warned) { relay.flood.warned = true; this.log(`nostr: ${relay.authUrl} is flooding us; dropping the rest for now`); }
        return;
      }
    }
    if (this.seenWraps.has(wrap.id)) {
      // The same envelope from a second relay is normal; from the only one, it is a replay.
      if (this.relays.length === 1) this.#reject('replay', 'exact copy of a message already handled', wrap);
      return;
    }
    this.seenWraps.set(wrap.id, Date.now() + SEEN_TTL_MS);
    if (this.seenWraps.size > MAX_SEEN) this.seenWraps.delete(this.seenWraps.keys().next().value);
    let seal; let rumor;
    try { ({ seal, rumor } = unwrap(wrap, this.sk)); }
    catch (e) { return this.#reject(e instanceof UnwrapError ? e.code : 'error', e.message, wrap); }
    const from = seal.pubkey;
    if (rumor.kind !== KIND_SIGNAL) return this.#reject('wrong-kind', `rumor kind ${rumor.kind}`, wrap, from);
    if (!tagValues(rumor, 'p').includes(this.me)) return this.#reject('misaddressed', 'sealed for us, addressed to someone else', wrap, from);
    const age = nowSec() - rumor.created_at;
    if (age > FRESH_PAST_S) return this.#reject('stale', `written ${age}s ago`, wrap, from);
    if (age < -FRESH_FUTURE_S) return this.#reject('future', 'dated in the future', wrap, from);
    if (this.seenRumors.has(rumor.id)) return this.#reject('replay', 'message already handled', wrap, from);
    const type = tagValue(rumor, 't');
    if (!CONTROL.has(type)) return this.#reject('bad-type', `unknown type ${type}`, wrap, from);
    if (!ACCEPTS[this.role].has(type)) return this.#reject('bad-type', `${type} is not something a ${this.role === 'station' ? 'Monitor' : 'Handheld'} is told`, wrap, from);
    let body;
    try { body = JSON.parse(rumor.content); } catch { body = null; }
    if (!body || typeof body !== 'object' || Array.isArray(body)) return this.#reject('bad-body', 'not an object', wrap, from);

    // Who may say this.
    if (this.role === 'station') {
      if (type === 'join') {
        if (!isHex(body.proof, 32)) return this.#reject('bad-proof', 'join without a proof', wrap, from);
        const want = joinProof(this.channelKey, from, this.me, rumor.created_at);
        if (!equalConstantTime(utf8(want), utf8(body.proof))) {
          return this.#reject('bad-proof', 'join proof is wrong: sender does not hold this channel', wrap, from);
        }
      } else if (!this.members.has(from)) {
        return this.#reject('not-member', `${type} from a key that never joined`, wrap, from);
      }
    } else if (from !== this.stationPub) {
      return this.#reject('not-monitor', `${type} sealed by a key that is not this channel's Monitor`, wrap, from);
    }

    this.seenRumors.set(rumor.id, Date.now() + SEEN_TTL_MS);
    if (this.seenRumors.size > MAX_SEEN) this.seenRumors.delete(this.seenRumors.keys().next().value);
    const frames = type === 'sig' && Array.isArray(body.f) ? body.f.slice(0, MAX_FRAMES) : [];
    this.#mirror({ t: 'opened', wrapId: wrap.id, type: type === 'sig' ? frames.map((f) => f?.type).join('+') : type, from, seal, rumor });

    let known = this.members.get(from);
    if (known) known.lastSeen = Date.now();
    const session = typeof body.s === 'string' ? body.s.slice(0, 16) : '';
    if (known && (type === 'join' || type === 'here') && session && known.session !== session) {
      // Same key, new session: it restarted. Tell app.js it left and came back.
      this.members.delete(from);
      this.#emit({ type: 'peer-left', id: from });
      known = null;
    }
    switch (type) {
      case 'join':
        if (!known) this.#remember(from);
        this.members.set(from, { role: 'viewer', lastSeen: Date.now(), session });
        this.#wrapTo(from, 'here', { s: this.session });
        if (!known) this.#emit({ type: 'peer-joined', id: from, role: 'viewer' });
        break;
      case 'here':
        if (!known) {
          this.members.set(from, { role: 'station', lastSeen: Date.now(), session });
          this.#emit({ type: 'peer-joined', id: from, role: 'station' });
        }
        break;
      case 'leave':
        if (known) { this.members.delete(from); this.#emit({ type: 'peer-left', id: from }); }
        break;
      case 'sig':
        for (const f of frames) {
          if (!f || typeof f !== 'object' || !RELAYED.has(f.type)) continue;
          this.#emit({ ...f, from });
        }
        break;
      default: break;
    }
  }

  // Monitor: Handheld keys that have joined this channel before (keys only,
  // never trusted for anything but where to say `here`).
  #remembered() {
    try {
      const v = JSON.parse(localStorage.getItem(this.peersSlot) || '[]');
      return Array.isArray(v) ? v.filter((x) => isHex(x, 32)).slice(-MAX_REMEMBERED) : [];
    } catch { return []; }
  }

  #remember(pub) {
    const list = this.#remembered().filter((x) => x !== pub);
    list.push(pub);
    try { localStorage.setItem(this.peersSlot, JSON.stringify(list.slice(-MAX_REMEMBERED))); } catch {}
  }

  // ---- DevOps mirror ----------------------------------------------------------------------------

  // Only when a build names a mirror (Tawny DevOps): a copy of each layer this
  // device opened or wrote goes to the inspector on the developer's PC, so the
  // inside of an envelope can be shown next to the outside the relay saw.
  // Release builds have no mirror and send nothing.
  #mirror(msg) {
    if (!this.mirrorUrl) return;
    const body = JSON.stringify({ ...msg, by: this.me, role: this.role === 'station' ? 'monitor' : 'handheld', proto: 'tawny-app-v1', at: Date.now() });
    try {
      fetch(this.mirrorUrl, { method: 'POST', mode: 'no-cors', keepalive: body.length < 60000, headers: { 'content-type': 'text/plain' }, body })
        .catch(() => {});
    } catch {}
  }
}
