// Tawny server page: the "Meeting points" panel.
//
// Lists the Nostr relays this box hands to its page (config.json) and tests
// each one from this browser the same way the app does when a call starts:
// send one sealed envelope addressed to ourselves through that relay alone and
// wait for it to come back (public/nostr/transport.js, #probe). A relay can
// accept a connection and still refuse or drop Tawny's envelopes, so "it
// connected" is not an answer; "it delivered" is.
//
// A module, separate from setup.js, because it needs the Nostr code and that
// is ES modules. It uses setup.js's small DOM helpers (el, why, copyRow),
// which are plain globals.

import { testRelay as probe } from './nostr/relay-test.js';

const { el, why, copyRow } = window;
const panel = document.getElementById('meet');
const list = document.getElementById('meet-list');
const again = document.getElementById('meet-test');
const more = document.getElementById('meet-more');

const hostOf = (u) => { try { return new URL(u.replace(/^ws/, 'http')).host; } catch { return u; } };
const isOurs = (u) => hostOf(u) === location.host;

/** One relay, one verdict: { ok, ms } or { ok: false, why } in words. */
async function testRelay(url) {
  const v = await probe(url);
  if (v.ok) return v;
  const why = v.why === 'refused' ? `Refused Tawny’s envelope (${v.detail || 'no reason given'}).`
    : v.why === 'listen' ? `Would not let us listen (${v.detail}).`
    : v.why === 'silent' ? 'Took the envelope and never delivered it.'
    : 'Could not connect from this browser.';
  return { ok: false, why };
}

function row(url) {
  const ours = isOurs(url);
  const state = el('span', { class: 'meet-state' }, 'Testing…');
  const li = el('li', { class: 'meet is-testing' },
    el('span', { class: 'meet-mark', 'aria-hidden': 'true' }),
    el('span', { class: 'meet-text' },
      el('span', { class: 'meet-name' }, ours ? 'This box' : hostOf(url),
        ours ? el('small', {}, 'your own') : el('small', {}, 'public')),
      state));
  return { li, state, url };
}

let running = false;
async function run(relays, setup) {
  if (running) return;
  running = true;
  again.disabled = true;
  again.textContent = 'Testing…';
  const rows = relays.map(row);
  list.replaceChildren(...rows.map((r) => r.li));
  const results = await Promise.all(rows.map(async (r) => {
    let v;
    try { v = await testRelay(r.url); } catch (e) { v = { ok: false, why: 'The test itself failed: ' + (e && e.message || e) }; }
    r.li.className = 'meet ' + (v.ok ? 'is-ok' : 'is-bad');
    r.state.textContent = v.ok ? `Works. Delivered in ${v.ms} ms.` : `${v.why} The app leaves it out by itself.`;
    return v;
  }));
  const good = results.filter((v) => v.ok).length;
  const sub = document.getElementById('meet-sub');
  const onlyBox = !!(setup && setup.nostr && setup.nostr.onlyThisBox);
  sub.textContent = good === 0
    ? (onlyBox
      ? 'This box is set to be the only meeting point, and its relay did not deliver a test envelope from this browser. Devices on this network cannot find each other until it does. Check the container is healthy, then test again.'
      : 'None of these delivered a test envelope from this browser. Devices cannot find each other through them right now; check this network, then test again.')
    : onlyBox
      ? 'Only this box: no public relay is used. Its relay delivered a test envelope from this browser just now.'
      : `Where your devices find each other before the video connects. ${good} of ${results.length} delivered a test envelope from this browser just now.`;
  const own = relays.findIndex(isOurs);
  explain(relays, setup, own < 0 ? null : results[own]);
  again.disabled = false;
  again.textContent = 'Test again';
  running = false;
}

/** One line of the "before you switch it on" list: a state chip and what it means. */
function check(state, label, text) {
  return el('li', { class: 'pre' }, el('span', { class: 'chip ' + (state === 'ok' ? 'is-ok' : state === 'bad' ? 'is-bad' : 'is-wait') }, label), el('span', { class: 'pre-text' }, text));
}

/**
 * @param {string[]} relays
 * @param {object|null} setup    setup.json
 * @param {{ok: boolean}|null|undefined} ownResult  this box's relay test: undefined while it runs
 */
function explain(relays, setup, ownResult) {
  const own = relays.find(isOurs);
  const publics = relays.filter((u) => !isOurs(u));
  const onlyBox = !!(setup && setup.nostr && setup.nostr.onlyThisBox);
  const lanIp = setup && setup.lan && !setup.lan.looksLikeDockerBridge ? setup.lan.ip : null;
  const lanRelay = lanIp ? `ws://${lanIp}:${setup.port || 8099}/relay` : null;
  const secure = location.protocol === 'https:';
  const wasOpen = !!more.querySelector('details.only-box[open]');
  const kids = [
    why('What can a meeting point see?',
      'Sealed envelopes: who is writing to whom (as random-looking keys, not names), when, and how big. It cannot read them. Your pairing key, your addresses and your video never go through it; the video goes straight between your two devices.',
      onlyBox ? null : 'Devices use every meeting point on this list that works and meet on any one they share, so one being down or refusing is not a problem.')
  ];
  if (own) {
    const only = why(onlyBox ? 'Only this box is on' : 'Use only this box, no public relays',
      onlyBox
        ? 'Pairing goes through this box and nowhere else. There is no public relay to fall back on, so these three have to stay true:'
        : 'Pairing then goes through this box and nowhere else. There is no public relay to fall back on, so check these three before you switch it on:');
    only.classList.add('only-box');
    only.append(el('ul', { class: 'pre-list' },
      ownResult === undefined ? check('wait', 'Testing', 'This box’s relay delivers a sealed test envelope from this browser.')
        : ownResult && ownResult.ok ? check('ok', 'Works', 'This box’s relay delivered a sealed test envelope from this browser.')
          : check('bad', 'Failed', onlyBox
            ? 'This box’s relay did not deliver a test envelope from this browser. Devices on this network cannot pair until it does.'
            : 'This box’s relay did not deliver a test envelope from this browser. Do not switch it on yet.'),
      secure
        ? check('ok', 'Reachable', 'You opened this page on a secure address, so a device that leaves the house can reach the box the same way, as long as it is on the same Tailscale (or your own VPN or proxy).')
        : check('wait', 'Home only', 'You opened this page on a home-network address. A device that leaves the house cannot reach the box, so it cannot pair, until it is on Tailscale with this box (step 2 on this page) or your own VPN.'),
      check('wait', 'On the phone', 'The Tawny app keeps its own relay list. Enter this box’s relay address in it (Diagnostics, then Servers, then Nostr relays) and turn on “Use only my relays” there. The app tests the relay from the phone before it lets you.')));
    only.append(el('p', {}, lanRelay
      ? 'The relay address at home is below. A phone that leaves the house needs the Tailscale one from “On this box”.'
      : 'This box could not work out its home-network address: use the address you opened this page on, with ws:// in front and /relay at the end.'));
    if (lanRelay) only.append(copyRow(lanRelay));
    only.append(el('p', {}, onlyBox
      ? 'To allow public relays again, remove TAWNY_ONLY_THIS_BOX from your .env and restart the container.'
      : (ownResult && ownResult.ok
        ? 'When all three are in place, set TAWNY_ONLY_THIS_BOX=on in your .env and restart the container.'
        : 'Once the relay test passes, set TAWNY_ONLY_THIS_BOX=on in your .env and restart the container.')));
    if (wasOpen || (onlyBox && ownResult && !ownResult.ok)) only.open = true;
    kids.push(only);
  } else if (publics.length) {
    kids.push(why('Run your own instead',
      'This box’s own relay is switched off. Remove TAWNY_RELAY=off from your .env and restart the container to get a meeting point that is yours and keeps nothing.'));
  }
  more.replaceChildren(...kids);
}

async function start() {
  let cfg = null; let setup = null;
  try {
    [cfg, setup] = await Promise.all([
      fetch('config.json', { cache: 'no-store' }).then((r) => r.json()),
      fetch('setup.json', { cache: 'no-store' }).then((r) => r.json()).catch(() => null),
    ]);
  } catch { return; }
  const relays = cfg && cfg.nostr && Array.isArray(cfg.nostr.relays) ? cfg.nostr.relays.filter((u) => typeof u === 'string').slice(0, 5) : [];
  if (!relays.length) return;            // meeting points are off: no panel
  panel.hidden = false;
  explain(relays, setup, undefined);
  again.addEventListener('click', () => run(relays, setup));
  run(relays, setup);
}

start();
