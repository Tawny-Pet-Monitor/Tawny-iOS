// A NIP-01 relay connection with NIP-42 AUTH, for browsers and Node 22+
// (both have a global WebSocket). Reconnects with backoff, re-authenticates
// and re-subscribes on its own. Never trusts the relay: every event it hands
// up has had its id and signature checked here, and must match the filter of
// the subscription it arrived on.

import { hex, nowSec, randomBytes } from './bytes.js';
import { eventProblem, finalizeEvent, getPublicKey, matchFilter } from './nostr.js';

const PUBLISH_TIMEOUT_MS = 8000;
// Far above any real envelope (~11 KB); bigger frames are dropped before parsing.
const MAX_FRAME = 128 * 1024;

export class Relay {
  /**
   * @param {string} url        where to connect (may be a local tap in front of the relay)
   * @param {object} opts
   * @param {string} opts.authUrl   the relay URL to sign into AUTH (the relay's own idea of its URL)
   * @param {Uint8Array} [opts.authKey] key to answer AUTH challenges with; none = stay anonymous
   * @param {(level:string, msg:string) => void} [opts.log]
   */
  constructor(url, { authUrl = url, authKey = null, log = () => {} } = {}) {
    this.url = url;
    this.authUrl = authUrl;
    this.authKey = authKey;
    this.log = log;
    this.ws = null;
    this.state = 'idle';
    this.challenge = null;
    this.authedAs = null;
    this.subs = new Map();      // id → { filters, onEvent, onClosed }
    this.pending = new Map();   // event id → { resolve, timer, ev, retried }
    this.listeners = new Set();
    this.backoff = 1000;
    this.closing = false;
    this.authWaiters = [];
    this.authPending = false;
  }

  onState(fn) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  #setState(s, detail) { this.state = s; for (const fn of this.listeners) fn(s, detail); }

  connect() {
    this.closing = false;
    return new Promise((resolve, reject) => {
      let settled = false;
      const ws = new WebSocket(this.url);
      this.ws = ws;
      this.#setState('connecting');
      ws.onopen = () => {
        this.backoff = 1000;
        this.#setState('open');
        for (const [id, s] of this.subs) this.#send(['REQ', id, ...s.filters]);
        if (!settled) { settled = true; resolve(this); }
      };
      ws.onmessage = (m) => this.#onMessage(m.data);
      ws.onerror = () => { if (!settled) { settled = true; reject(new Error('cannot reach relay ' + this.url)); } };
      ws.onclose = (e) => {
        this.challenge = null;
        this.authedAs = null;
        this.authPending = false;
        this.#setState('closed', `${e.code} ${e.reason || ''}`.trim());
        if (!this.closing) {
          const wait = this.backoff;
          // Capped at 10 s: this is a live call's signaling, not a feed reader.
          this.backoff = Math.min(this.backoff * 2, 10000);
          this.log('warn', `relay connection lost, retrying in ${wait / 1000}s`);
          setTimeout(() => { if (!this.closing) this.connect().catch(() => {}); }, wait);
        }
      };
    });
  }

  close() {
    this.closing = true;
    try { this.ws?.close(1000, 'bye'); } catch { /* already gone */ }
  }

  #send(msg) {
    if (this.ws?.readyState === WebSocket.OPEN) { this.ws.send(JSON.stringify(msg)); return true; }
    return false;
  }

  /** Resolves once this connection is authenticated, or after `ms` without a challenge. */
  whenAuthed(ms = 4000) {
    if (this.authedAs || !this.authKey) return Promise.resolve(this.authedAs);
    return new Promise((resolve) => {
      const t = setTimeout(() => resolve(null), ms);
      this.authWaiters.push((who) => { clearTimeout(t); resolve(who); });
    });
  }

  #authenticate() {
    if (!this.authKey || !this.challenge || this.authPending) return false;
    this.authPending = true;   // one AUTH in flight; the challenge and a CLOSED used to both send one
    // NIP-42: kind 22242, current time, the relay's URL and its challenge.
    const ev = finalizeEvent({
      kind: 22242,
      created_at: nowSec(),
      tags: [['relay', this.authUrl], ['challenge', this.challenge]],
      content: '',
    }, this.authKey);
    this.pending.set(ev.id, { auth: true, ev, timer: null, resolve: () => {} });
    this.#setState('authenticating');
    return this.#send(['AUTH', ev]);
  }

  #onMessage(data) {
    if (typeof data !== 'string' || data.length > MAX_FRAME) return this.log('warn', 'relay sent an oversized or binary frame; dropped');
    let msg;
    try { msg = JSON.parse(data); } catch { return this.log('warn', 'relay sent non-JSON'); }
    if (!Array.isArray(msg) || typeof msg[0] !== 'string') return;
    const [type, a, b, c] = msg;
    switch (type) {
      case 'AUTH':
        if (typeof a !== 'string') return;
        this.challenge = a;
        this.#authenticate();
        break;
      case 'OK': {
        const p = this.pending.get(a);
        if (!p) return;
        this.pending.delete(a);
        clearTimeout(p.timer);
        if (p.auth) {
          this.authPending = false;
          if (b === true) {
            this.authedAs = getPublicKey(this.authKey);
            this.#setState('authenticated');
            this.authWaiters.splice(0).forEach((fn) => fn(this.authedAs));
            // Anything refused for want of AUTH can go now.
            for (const [id, s] of this.subs) if (s.needsAuth) { s.needsAuth = false; this.#send(['REQ', id, ...s.filters]); }
          } else {
            this.log('error', 'relay refused AUTH: ' + c);
            this.#setState('open');
          }
          return;
        }
        if (b !== true && typeof c === 'string' && c.startsWith('auth-required:') && !p.retried && this.challenge) {
          // NIP-42 flow for a refused EVENT: AUTH, then send it again once.
          this.#authenticate();
          this.whenAuthed().then(() => this.#publishRaw(p.ev, p.resolve, true));
          return;
        }
        p.resolve({ ok: b === true, message: c || '' });
        break;
      }
      case 'EVENT': {
        const sub = this.subs.get(a);
        if (!sub) return;
        const problem = eventProblem(b);
        if (problem) return this.log('warn', `relay delivered an invalid event (${problem}); dropped`);
        if (!sub.filters.some((f) => matchFilter(f, b))) return this.log('warn', 'relay delivered an event we did not ask for; dropped');
        sub.onEvent(b, this);
        break;
      }
      case 'EOSE': this.subs.get(a)?.onEose?.(); break;
      case 'CLOSED': {
        const sub = this.subs.get(a);
        if (!sub) return;
        if (typeof b === 'string' && b.startsWith('auth-required:') && this.authKey) {
          sub.needsAuth = true;              // resent from the AUTH OK handler
          if (!this.authedAs) this.#authenticate();
          else { sub.needsAuth = false; this.#send(['REQ', a, ...sub.filters]); }
        } else {
          this.subs.delete(a);
          sub.onClosed?.(b);
        }
        break;
      }
      case 'NOTICE': this.log('info', 'relay notice: ' + a); break;
      default: break;
    }
  }

  #publishRaw(ev, resolve, retried = false) {
    const timer = setTimeout(() => { this.pending.delete(ev.id); resolve({ ok: false, message: 'timeout' }); }, PUBLISH_TIMEOUT_MS);
    this.pending.set(ev.id, { ev, resolve, timer, retried });
    if (!this.#send(['EVENT', ev])) { clearTimeout(timer); this.pending.delete(ev.id); resolve({ ok: false, message: 'not connected' }); }
  }

  /** Publish one event; resolves with the relay's OK verdict. */
  publish(ev) { return new Promise((resolve) => this.#publishRaw(ev, resolve)); }

  /** Send any raw frame (the demo's attack buttons use this to replay or tamper). */
  sendRaw(arr) { return this.#send(arr); }

  subscribe(filters, { onEvent, onEose, onClosed } = {}) {
    const id = hex(randomBytes(8));
    this.subs.set(id, { filters, onEvent, onEose, onClosed, needsAuth: false });
    this.#send(['REQ', id, ...filters]);
    return id;
  }

  unsubscribe(id) {
    if (this.subs.delete(id)) this.#send(['CLOSE', id]);
  }
}
