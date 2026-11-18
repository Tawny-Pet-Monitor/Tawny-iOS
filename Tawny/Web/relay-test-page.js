// The Android Servers screen's relay test (MainActivity.runRelayTest).
//
// Loaded in a WebView nobody sees, with the relays to test as a JSON list in
// the URL fragment. It runs the same test a call runs (nostr/relay-test.js)
// and hands the verdicts back through the one-method bridge that WebView has.
// Nothing else is on this page: no channel key, no settings, no storage.

import { testRelays } from './nostr/relay-test.js';

const done = (out) => { try { window.TawnyRelayTest.done(JSON.stringify(out)); } catch {} };

let relays = [];
try { relays = JSON.parse(decodeURIComponent(location.hash.slice(1))); } catch {}
relays = (Array.isArray(relays) ? relays : []).filter((u) => typeof u === 'string' && /^wss?:\/\//.test(u)).slice(0, 5);

testRelays(relays)
  .then((res) => done(res.map((v, i) => ({ url: relays[i], ok: !!v.ok, ms: v.ok ? v.ms : -1, why: v.ok ? '' : v.why, detail: v.ok ? '' : v.detail }))))
  .catch(() => done([]));
