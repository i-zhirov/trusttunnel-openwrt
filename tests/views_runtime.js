#!/usr/bin/env node
// Runtime test for the LuCI views: executes status.js, log.js, settings.js
// and diagnostics.js against mocks that replicate the CURRENT LuCI runtime
// contracts, and asserts the rendered output.
//
// Why this exists: the views were written against the pre-rewrite LuCI
// APIs and the CI gate only syntax-parses them, so three runtime bugs
// shipped (1.0.16+):
//   1. settings.js read data.trusttunnel.* from the uci.load() result —
//      current LuCI resolves it with the package-name list.
//   2. settings.js used form.Section — current LuCI's form module does
//      not export it.
//   3. diagnostics.js passed E() children variadically — current LuCI's
//      DOM.create() reads only arguments[2] and silently drops the rest.
// The mocks below deliberately implement the CURRENT contracts, so a
// regression to any of the old patterns fails this test.
//
// The views are LuCI modules ('require' lines + a top-level return), so
// they are compiled the way the LuCI loader does: every require becomes
// a function parameter and E/_ are provided as globals.

'use strict';

const fs = require('fs');
const path = require('path');

const VIEW_DIR = process.env.OLD_VIEWS || path.join(__dirname, '..', 'packages',
    'luci-app-trusttunnel', 'htdocs', 'luci-static', 'resources', 'view', 'trusttunnel');

// ---------------------------------------------------------------------------
// minimal assertion helpers
// ---------------------------------------------------------------------------

let total = 0, failed = 0;

function ok(cond, msg) {
    total++;
    if (cond) {
        console.log('  ok: ' + msg);
    } else {
        failed++;
        console.log('  FAIL: ' + msg);
    }
}

function eq(actual, expected, msg) {
    ok(actual === expected, msg + ' (expected: ' + JSON.stringify(expected) +
        ', got: ' + JSON.stringify(actual) + ')');
}

// ---------------------------------------------------------------------------
// the runtime mocks — the contracts are CURRENT LuCI, on purpose
// ---------------------------------------------------------------------------

// --- dom / E ----------------------------------------------------------------
// DOM.create() reads ONLY arguments[2] as children; extra arguments are
// silently dropped. append() handles arrays, functions, nodes and strings.
function appendOne(node, child) {
    if (typeof child === 'function')
        return appendOne(node, child(node));
    if (child !== null && child !== undefined && typeof child === 'object')
        node.children.push(child);           // element node
    else if (child !== null && child !== undefined)
        node.children.push(String(child));   // text
}

function append(node, children) {
    if (Array.isArray(children)) {
        for (let i = 0; i < children.length; i++)
            appendOne(node, children[i]);
    } else {
        appendOne(node, children);
    }
}

function E() {
    let html = arguments[0];
    let attr = arguments[1];
    let data = arguments[2];               // ONLY the third argument!
    // Real DOM.create() fallback: a non-object (or array) second argument
    // is the data, not attributes — the views rely on it (E('h3', 'Client log')).
    if (!(attr instanceof Object) || Array.isArray(attr)) {
        data = attr;
        attr = null;
    }
    const node = { tag: html, attrs: attr || {}, children: [], addEventListener: function () {} };
    // Real DOM: assigning textContent replaces the children with a text
    // node — the log view fills its <pre> that way.
    Object.defineProperty(node, 'textContent', {
        get: function () { return this.children.join(''); },
        set: function (v) { this.children = [ String(v) ]; }
    });
    if (data !== undefined && data !== null)
        append(node, data);
    return node;
}

const dom = {
    create: E,
    content: function (node, children) {
        node.children = [];
        return append(node, children);
    }
};

// --- uci --------------------------------------------------------------------
// uci.load() resolves with the PACKAGE-NAME LIST (current contract), not
// the configuration object. The data lives in state.values; sections()
// and get() read it.
const uciData = {
    main:     { '.type': 'main', '.name': 'main', enabled: '1', log_level: 'info', mode: 'tun',
                endpoint: 'Default' },
    endpoint: { '.type': 'endpoint', '.name': 'endpoint', name: 'Default',
                hostname: 'kz.hexbrains.com', address: ['kz.hexbrains.com:443'],
                username: 'iceman', password: 'secret', protocol: 'http2',
                anti_dpi: '0', post_quantum: '1', skip_verification: '0',
                has_ipv6: '1', routing_profile: 'Test' },
    cfg3:     { '.type': 'endpoint', '.name': 'cfg3', name: 'Backup',
                hostname: 'backup.example.com', address: ['backup.example.com:443'],
                username: 'backup', password: 'backuppass', protocol: 'http2',
                anti_dpi: '0', post_quantum: '1', skip_verification: '0',
                has_ipv6: '1', routing_profile: '' },
    network:  { '.type': 'network', '.name': 'network', mtu: '1350', table: '880',
                fwmark: '0x9527', blackhole_on_down: '0', include_router_traffic: '0' },
    proxy:    { '.type': 'proxy', '.name': 'proxy', address: '127.0.0.1:1080',
                username: '', password: '' },
    cfg1:     { '.type': 'routing_profile', '.name': 'cfg1', name: 'Default', mode: 'vpn' },
    cfg2:     { '.type': 'routing_profile', '.name': 'cfg2', name: 'Test',
                mode: 'bypass', vpn_rules: ['api.ipify.org', 'example.com'] },
    domains:  { '.type': 'domains', '.name': 'domains', direct: ['legacy.example'] }
};

const uciSets = [];

const uci = {
    load: function (config) { return Promise.resolve([config]); },
    sections: function (conf, type) {
        const out = [];
        for (const sid in uciData) {
            if (!type || uciData[sid]['.type'] === type)
                out.push(uciData[sid]);
        }
        return out;
    },
    get: function (conf, sid, opt) {
        return uciData[sid] ? uciData[sid][opt] : undefined;
    },
    set: function (conf, sid, opt, val) {
        uciSets.push([sid, opt, val]);
    }
};

// --- form -------------------------------------------------------------------
// Current LuCI exports TypedSection/NamedSection/AbstractSection but NO
// plain `Section`; Map.section() rejects classes outside the hierarchy.
function CBIAbstractSection() {}
function CBINamedSection() {}
function CBITypedSection() {}

function makeOption() {
    return {
        values: [],
        value: function () { for (let i = 0; i < arguments.length; i++) this.values.push(arguments[i]); }
    };
}

const form = {
    AbstractSection: CBIAbstractSection,
    NamedSection: CBINamedSection,
    TypedSection: CBITypedSection,
    Value: function () {}, Flag: function () {}, ListValue: function () {},
    DynamicList: function () {}, Button: function () {},
    // NOTE: no `Section` export — matches current LuCI.
    Map: function (config, title) {
        this.config = config;
        this.title = title;
        this.sections = [];
        this.tabbed = false;
    }
};

form.Map.prototype.section = function (cls, ...args) {
    if (cls !== CBINamedSection && cls !== CBITypedSection)
        throw new Error('Class must be a descendant of CBIAbstractSection');
    const s = new cls();
    s.type = args[0];
    s.title = args[args.length - 1];
    s.options = [];
    s.option = function (optCls, name) {
        const o = makeOption();
        o.name = name;
        this.options.push(o);
        return o;
    };
    // Section-level tabs: options added via taboption() carry the tab
    // name; plain option() is only valid for sections without tabs.
    s.tabs = [];
    s.tab = function (name, title) {
        this.tabs.push({ name: name, title: title });
    };
    s.taboption = function (tabName, optCls, name) {
        const o = makeOption();
        o.name = name;
        o.tab = tabName;
        this.options.push(o);
        return o;
    };
    this.sections.push(s);
    return s;
};

// The view ends render() with `return m.render()`; the real form.Map
// builds the DOM there. The mock returns a walkable tree of the sections.
form.Map.prototype.render = function () {
    return E('div', { 'class': 'cbi-map' }, this.sections.map(s =>
        E('div', { 'class': 'cbi-section', 'data-type': s.type },
            E('h3', s.title),
            s.options.map(o => E('div', { 'data-option': o.name },
                o.name, o.values.length ? ' = ' + o.values.join(', ') : ''))
        )
    ));
};

// --- rpc --------------------------------------------------------------------
// The log lines are mutable so the log view test can prove the poll
// refreshes the tail in place.
let logLines = [ 'line one', 'line two' ];

const canned = {
    status: function () {
        return {
            enabled: true, running: true, mode: 'tun',
            device: 'tun0', device_up: true,
            rule: true, table: true, nft: true,
            server: 'Default',
            endpoint_hostname: 'kz.hexbrains.com',
            addresses: ['kz.hexbrains.com:443'],
            client_installed: true, routing_profile: 'Test',
            routing_mode: 'bypass', vpn_mode: 'selective',
            proxy_address: null, listener_up: null,
            rx_bytes: 1048576, tx_bytes: 524288
        };
    },
    service: function () { return { code: 0 }; },
    // Mutable on purpose: the log view test changes the lines between
    // renders to prove the poll refreshes the tail in place.
    log: function () { return { lines: logLines.slice() }; },
    versions: function () {
        return { package: '1.0.20-r1', client_package: '1.1.5-r1', client: '1.1.5' };
    },
    diagnose: function () {
        return {
            verdict: 'ok',
            counts: { ok: 17, warn: 0, fail: 0, skip: 0 },
            checks: [
                { group: 'config', label: 'Server address', status: 'ok',
                  detail: 'kz.hexbrains.com:443', hint: '' },
                { group: 'config', label: 'Endpoint credentials', status: 'ok',
                  detail: 'user iceman', hint: '' },
                { group: 'kernel', label: 'Marking rule', status: 'ok',
                  detail: 'found', hint: '' }
            ]
        };
    },
    ping: function () {
        return { results: [{ host: 'kz.hexbrains.com', loss: 0, min: 90, avg: 95, max: 100 }] };
    },
    probe: function () {
        return { tunnel: { ip: '104.238.24.115' }, direct: { ip: '178.46.214.219' } };
    },
    check_domain: function (domain) {
        // Domain-aware: a legacy direct-list entry verdicts 'direct', any
        // other domain 'tunnel' — the status preview tests both paths.
        return {
            domain: domain, normalized: domain,
            verdict: domain === 'legacy.example' ? 'direct' : 'tunnel',
            reason: domain === 'legacy.example'
                ? 'listed in the "do not bypass" list; the client matches it by SNI'
                : 'assigned profile in VPN mode'
        };
    },
    import_config: function () {
        return { hostname: 'import.example.com', addresses: ['import.example.com:443'],
                 has_ipv6: '0', username: 'importuser', password: 'importpass',
                 skip_verification: '0', protocol: 'http2', anti_dpi: '0' };
    }
};

const rpcCalls = [];
const rpc = {
    declare: function (spec) {
        return function () {
            rpcCalls.push(spec.method);
            const fn = canned[spec.method];
            return Promise.resolve(fn ? fn.apply(null, arguments) : {});
        };
    }
};

// --- view / ui / poll / _ -----------------------------------------------------
const view = { extend: function (def) { return def; } };

// LuCI strings carry a .format() method used throughout the views
// (_('... %s').format(...)); provide the same extension.
if (!String.prototype.format) {
    String.prototype.format = function () {
        let s = this;
        let i = 0;
        const args = arguments;
        return s.replace(/%[sd]/g, function (m) {
            return m === '%s' ? String(args[i++]) : String(Number(args[i++]));
        });
    };
}

const ui = {
    showModal: function (title, children) { ui.lastModal = { title: title, children: children }; },
    hideModal: function () {},
    addNotification: function () {},
    createHandlerFn: function (self, fn) {
        if (typeof fn === 'string')
            fn = self[fn];
        return fn.bind(self);
    }
};

const pollTasks = [];
const poll = { add: function (fn) { pollTasks.push(fn); } };

const _ = function (s) { return s; };

// --- compiling a view the way the LuCI loader does -----------------------------
function loadView(name) {
    const src = fs.readFileSync(path.join(VIEW_DIR, name), 'utf8')
        .replace(/^'use strict';?\s*/m, '')
        .replace(/^'require\s+[a-z]+';?\s*/gm, '');
    const factory = new Function('view', 'form', 'uci', 'rpc', 'ui', 'poll', 'dom', 'E', '_', src);
    return factory(view, form, uci, rpc, ui, poll, dom, E, _);
}

// --- tree helpers ----------------------------------------------------------------
function walk(node, fn) {
    if (Array.isArray(node)) {
        for (const c of node)
            walk(c, fn);
        return;
    }
    if (typeof node === 'string')
        return;
    fn(node);
    for (const c of (node.children || []))
        walk(c, fn);
}

function hasText(node, s) {
    if (typeof node === 'string')
        return node.indexOf(s) !== -1;
    return (node.children || []).some(c => hasText(c, s));
}

function findButtons(node) {
    const out = [];
    walk(node, n => { if (n.tag === 'button') out.push(n); });
    return out;
}

function findInputs(node) {
    const out = [];
    walk(node, n => { if (n.tag === 'input') out.push(n); });
    return out;
}

function click(buttonNode) {
	return Promise.resolve(buttonNode.attrs.click && buttonNode.attrs.click());
}

// Drain the microtask queue until the predicate holds (each await = one
// drain); the preview's check_domain chain is several promises deep, so a
// fixed number of awaits would be fragile.
async function waitText(node, s) {
	for (let i = 0; i < 30; i++) {
		if (hasText(node, s))
			return true;
		await Promise.resolve();
	}
	return hasText(node, s);
}

// ---------------------------------------------------------------------------
// the tests
// ---------------------------------------------------------------------------

async function main() {
    // ===== status.js =====
    console.log('== status.js');
    const statusView = loadView('status.js');
    const statusData = await statusView.load();
    const statusTree = statusView.render(statusData);
    if (process.env.DEBUG_VIEWS) {
        const dump = (n, d) => {
            if (typeof n === 'string') { console.log('  '.repeat(d) + 'text: ' + n.slice(0, 60)); return; }
            console.log('  '.repeat(d) + '<' + n.tag + '>');
            for (const c of (n.children || [])) dump(c, d + 1);
        };
        dump(statusTree, 0);
    }
    ok(hasText(statusTree, 'Current state'), 'status: the facts section has a Current state heading');
    // The client log is its own view now (log.js); the status page only
    // polls the verdict and the facts.
    ok(!hasText(statusTree, 'Client log'), 'status: the client log moved to its own view');
    // The control row is Start / Stop / Preview rules: the restart verb
    // is deliberately absent (from the UI it is stop + start).
    const statusButtons = findButtons(statusTree).map(b => String(b.children[0]));
    for (const label of ['Start', 'Stop', 'Preview rules'])
        ok(statusButtons.indexOf(label) !== -1, 'status: ' + label + ' button present');
    ok(statusButtons.indexOf('Restart service') === -1,
        'status: no restart button (it would duplicate Stop + Start)');
    // The verdict and facts boxes render their content immediately
    // (E('div', {}, node) passes the node as a child — the bare
    // two-argument form treats it as attributes), and the poll refreshes
    // them in place. Run a poll cycle and assert the rendered facts,
    // exactly like the live page.
    for (const task of pollTasks)
        await task();
    await Promise.resolve();
    ok(hasText(statusTree, 'State'), 'status: facts table has a State row');
    ok(hasText(statusTree, 'working'), 'status: State row says working');
    ok(hasText(statusTree, 'Server'), 'status: facts table has a Server row');
    ok(hasText(statusTree, 'Default — kz.hexbrains.com'),
        'status: Server row names the active server with the hostname');
    ok(hasText(statusTree, 'Profile Test — bypass, only the VPN rules are tunneled'),
        'status: Mode row shows the Test bypass profile');
    // The traffic row renders the cumulative counters; the rates are the
    // poll delta, so they only appear once a later snapshot exists (the
    // test cannot wait 0.5 s, so it pins the totals, which are
    // deterministic from the canned counters).
    ok(hasText(statusTree, 'Traffic'), 'status: facts table has a Traffic row');
    ok(hasText(statusTree, 'Total 1.0 MiB down, 512.0 KiB up'),
        'status: Traffic row shows the cumulative totals');

    // Without counters (proxy mode without the meter, tun mode without a
    // device yet) the traffic row is hidden, not blank.
    const noCountersStatus = Object.assign({}, canned.status(), {
        rx_bytes: null, tx_bytes: null
    });
    const noCountersTree = statusView.render(noCountersStatus);
    ok(!hasText(noCountersTree, 'Traffic'),
        'status: no Traffic row without counters');

    // Re-entering the view starts the traffic baseline fresh: the rates
    // are poll deltas, so a baseline from a previous visit would paint
    // a rate averaged over the whole away interval. Simulate 10 minutes
    // of absence with a faked clock and a fresh load().
    const realNow = Date.now;
    Date.now = function () { return realNow() + 600000; };
    const reentryData = await statusView.load();
    const reentryTree = statusView.render(Object.assign({}, canned.status(), {
        rx_bytes: 11534336, tx_bytes: 5767168
    }));
    Date.now = realNow;
    ok(hasText(reentryTree, 'Down —') && hasText(reentryTree, 'Up —'),
        'status: a re-entered view shows placeholder rates, not a stale average');

    // Preview rules: the button opens the modal for the assigned profile
    // (Test, bypass mode) and checks every VPN rule against the backend
    // one after another.
    const previewBtn = findButtons(statusTree).find(b => hasText(b, 'Preview rules'));
    ok(previewBtn !== null, 'status: Preview rules button present');
    await click(previewBtn);
    await waitText(ui.lastModal.children, 'Tunneled by this profile');
    ok(ui.lastModal && ui.lastModal.title === 'Rule preview — Test',
        'status: preview modal names the assigned profile');
    // hasText() walks DOM nodes, not arrays; wrap the modal children.
    const modalBox = { children: ui.lastModal.children };
    ok(await waitText(modalBox, 'Tunneled by this profile'),
        'status: preview shows the tunneled-list heading');
    ok(await waitText(modalBox, 'api.ipify.org') &&
        await waitText(modalBox, 'example.com'),
        'status: preview lists the profile VPN rules');
    ok(await waitText(modalBox, 'through the tunnel'),
        'status: preview renders verdicts for the checked rules');

    // Without an assigned profile the same button previews the
    // direct-by-default state in tun mode: nothing is routed at all.
    const legacyStatus = Object.assign({}, canned.status(), {
        routing_profile: '', routing_mode: '', vpn_mode: 'selective'
    });
    const legacyTree = statusView.render(legacyStatus);
    const legacyBtn = findButtons(legacyTree).find(b => hasText(b, 'Preview rules'));
    ok(legacyBtn !== null, 'status: Preview rules button present without a profile');
    await click(legacyBtn);
    await waitText(ui.lastModal.children, 'No routing profile is assigned');
    ok(ui.lastModal && ui.lastModal.title === 'Rule preview',
        'status: legacy preview modal has the plain title');
    const legacyBox = { children: ui.lastModal.children };
    ok(await waitText(legacyBox, 'No routing profile is assigned, so traffic goes out directly.'),
        'status: no-profile preview explains the direct-by-default state');
    ok(await waitText(legacyBox, 'traffic goes out directly'),
        'status: no-profile preview states the direct verdict');

    // An assigned profile with an unrecognized mode falls back the same
    // way in tun mode (direct by default): the facts row must not claim
    // a full tunnel.
    const unknownModeStatus = Object.assign({}, canned.status(), {
        routing_profile: 'Default', routing_mode: '', vpn_mode: 'selective'
    });
    const unknownModeTree = statusView.render(unknownModeStatus);
    ok(hasText(unknownModeTree, 'Direct — unknown profile mode'),
        'status: an unrecognized profile mode renders the direct-by-default facts row');
    ok(!hasText(unknownModeTree, 'Everything through VPN'),
        'status: an unrecognized profile mode in tun mode is not described as a full tunnel');

    // ===== log.js =====
    console.log('== log.js');
    const logView = loadView('log.js');
    const logData = await logView.load();
    const logTasksBefore = pollTasks.length;
    const logTree = logView.render(logData);
    ok(hasText(logTree, 'Client log'), 'log: section heading present');
    // The tail is fetched during load(), so the first paint already
    // shows the log — no spinner state on a page whose whole purpose is
    // the log.
    ok(hasText(logTree, 'line one') && hasText(logTree, 'line two'),
        'log: the tail renders on the first paint');
    ok(!hasText(logTree, 'Loading'), 'log: no loading indicator on first paint');
    // The poll refreshes the text in place.
    const logTasks = pollTasks.slice(logTasksBefore);
    logLines = [ 'line three', 'line four' ];
    for (const task of logTasks)
        await task();
    await Promise.resolve();
    ok(hasText(logTree, 'line three') && hasText(logTree, 'line four'),
        'log: the poll refreshes the tail in place');
    ok(!hasText(logTree, 'line one'), 'log: the refreshed content replaced the old lines');

    // The export button downloads the whole ring buffer as a text file:
    // stub the browser download APIs and capture what the handler builds.
    const exported = { name: null, text: null };
    global.Blob = function (parts) { exported.text = String(parts.join('')); };
    global.URL = { createObjectURL: function () { return 'blob:mock'; }, revokeObjectURL: function () {} };
    global.document = {
        body: {
            appendChild: function (a) {
                exported.name = a.attrs.download;
                a.click = function () {};
            },
            removeChild: function () {}
        }
    };
    const exportBtn = findButtons(logTree).find(b => String(b.children[0]) === 'Export client logs');
    ok(exportBtn !== null, 'log: Export client logs button present');
    await click(exportBtn);
    await Promise.resolve();
    await Promise.resolve();
    ok(exported.name !== null && /^trusttunnel-client-\d{8}-\d{6}\.log$/.test(exported.name),
        'log: the export names the file with a timestamp');
    ok(exported.text.indexOf('line three') !== -1 && exported.text.indexOf('line four') !== -1,
        'log: the export carries the log lines');

    // ===== settings.js =====
    console.log('== settings.js');
    const settingsView = loadView('settings.js');
    const settingsData = await settingsView.load();
    let settingsTree;
    let settingsRenderError = null;
    try {
        settingsTree = settingsView.render(settingsData);
    } catch (e) {
        settingsRenderError = e;
    }
    ok(settingsRenderError === null, 'settings: render() does not throw' +
        (settingsRenderError ? ' (' + settingsRenderError.message + ')' : ''));
    if (settingsRenderError !== null) {
        failed++;
        return;
    }
    const profileSecs = [];
    for (const s of form_lastMap.sections)
        if (s.type === 'routing_profile')
            profileSecs.push(s);
    ok(profileSecs.length === 1, 'settings: a routing_profile section is created');
    // The endpoint sections are repeatable and split into inner tabs:
    // map-level tabs key their panes by the UCI section type, so two
    // sections of the same type would collide; section-level tabs use
    // their own names. Every server carries a unique name, its own
    // routing profile and its own DNS upstreams.
    const endpointSec = form_lastMap.sections.find(s => s.type === 'endpoint');
    ok(endpointSec && endpointSec.tabs.length === 2 &&
        endpointSec.tabs[0].name === 'connection' && endpointSec.tabs[1].name === 'security',
        'settings: the endpoint section splits into Connection and Security tabs');
    ok(endpointSec && endpointSec.options.length > 0 &&
        endpointSec.options.every(o => o.tab === 'connection' || o.tab === 'security'),
        'settings: every endpoint option lives on an inner tab');
    ok(endpointSec && endpointSec.options.some(o => o.name === 'name'),
        'settings: every server carries a unique name field');
    const rpOpt = endpointSec && endpointSec.options.find(o => o.name === 'routing_profile');
    ok(rpOpt && rpOpt.values.indexOf('Default') !== -1 && rpOpt.values.indexOf('Test') !== -1,
        'settings: the routing profile select lists Default and Test');
    ok(rpOpt && rpOpt.values.indexOf('') !== -1,
        'settings: the routing profile select offers the none option');
    ok(endpointSec && endpointSec.options.some(o => o.name === 'dns_upstream'),
        'settings: the DNS upstreams live in the server form');
    const advSec = form_lastMap.sections.find(s => s.type === 'network');
    ok(advSec && !advSec.options.some(o => o.name === 'dns_upstream'),
        'settings: the Advanced tab no longer writes the endpoint DNS list');

    // The operation mode picker and the ACTIVE server picker live on the
    // General tab, the SOCKS listener settings on their own Proxy tab.
    const mainSec = form_lastMap.sections.find(s => s.type === 'main');
    ok(mainSec && mainSec.options.some(o => o.name === 'mode'),
        'settings: the operation mode picker exists on General');
    const actOpt = mainSec && mainSec.options.find(o => o.name === 'endpoint');
    ok(actOpt && actOpt.values.indexOf('Default') !== -1 &&
        actOpt.values.indexOf('Backup') !== -1,
        'settings: the active server picker lists every saved server');
    const proxySec = form_lastMap.sections.find(s => s.type === 'proxy');
    ok(proxySec && proxySec.options.some(o => o.name === 'address') &&
        proxySec.options.some(o => o.name === 'username') &&
        proxySec.options.some(o => o.name === 'password'),
        'settings: the proxy section exposes address and authentication');

    // Import flow: open the modal, paste a config, press Import, verify the
    // values land in pending UCI only (uci.set recorded, nothing else). The
    // handler is invoked without a section id here (the button always
    // passes one), so it falls back to the ACTIVE server — in the mock the
    // section named Default, whose id is 'endpoint'.
    settingsView.handleImport();
    const modal = ui.lastModal;
    ok(modal && modal.title === 'Import server settings', 'settings: Import modal opens');
    let textarea = null, importBtn = null;
    walk(modal.children, n => {
        if (n.tag === 'textarea') textarea = n;
        if (n.tag === 'button' && hasText(n, 'Import')) importBtn = n;
    });
    ok(textarea !== null, 'settings: modal has the config textarea');
    ok(importBtn !== null, 'settings: modal has the Import button');
    textarea.value = 'hostname = "import.example.com"\naddresses = ["import.example.com:443"]\n';
    await click(importBtn);
    await Promise.resolve();
    // uci.set records [sid, opt, val]
    const importSet = uciSets.find(c => c[0] === 'endpoint' && c[1] === 'hostname');
    ok(importSet && importSet[2] === 'import.example.com',
        'settings: Import applies the hostname to the active server');
    ok(uciSets.some(c => c[0] === 'endpoint' && c[1] === 'address'),
        'settings: Import applies the address list to the active server');

    // With several saved servers the import lands in the server whose
    // Import button was pressed: the handler receives that server's
    // section id and must not touch the active one. The canned import
    // result is fixed, so only the target section is asserted.
    uciSets.length = 0;
    settingsView.handleImport(null, 'cfg3');
    let m2 = ui.lastModal, ta2 = null, btn2 = null;
    walk(m2.children, n => {
        if (n.tag === 'textarea') ta2 = n;
        if (n.tag === 'button' && hasText(n, 'Import')) btn2 = n;
    });
    ta2.value = 'hostname = "other.example.com"\naddresses = ["other.example.com:443"]\n';
    await click(btn2);
    await Promise.resolve();
    ok(uciSets.some(c => c[0] === 'cfg3' && c[1] === 'hostname'),
        'settings: the import targets the server instance that owns the button');
    ok(!uciSets.some(c => c[0] === 'endpoint'),
        'settings: the other servers are left untouched');

    // A pending import_config shows a loading state: the Import button is
    // disabled and spins until the backend answers, then applies the
    // values exactly like the immediate path above.
    let importResolve = null;
    const pendingImport = new Promise(res => { importResolve = res; });
    const realImport = canned.import_config;
    canned.import_config = () => pendingImport;
    settingsView.handleImport();
    let pModal = ui.lastModal, pTa = null, pBtn = null;
    walk(pModal.children, n => {
        if (n.tag === 'textarea') pTa = n;
        if (n.tag === 'button' && hasText(n, 'Import')) pBtn = n;
    });
    pTa.value = 'hostname = "pending.example.com"\n';
    const pendingClick = click(pBtn);
    await Promise.resolve();
    ok(pBtn.disabled === true, 'settings: the Import button is disabled while importing');
    ok(hasText(pBtn, 'Importing'), 'settings: the Import button shows a spinner label while importing');
    importResolve({ hostname: 'pending.example.com', addresses: ['pending.example.com:443'] });
    await pendingClick;
    await Promise.resolve();
    canned.import_config = realImport;
    ok(uciSets.some(c => c[0] === 'endpoint' && c[1] === 'hostname' && c[2] === 'pending.example.com'),
        'settings: the deferred import still applies the hostname');

    // ===== diagnostics.js =====
    console.log('== diagnostics.js');
    const diagView = loadView('diagnostics.js');
    const diagTree = diagView.render();
    // the render returns E('div', cbi-map, [h2, 1 section]) — the variadic
    // regression would drop everything after the h2 (children.length === 1)
    eq(diagTree.tag, 'div', 'diagnostics: root is a div');
    eq(diagTree.children.length, 2, 'diagnostics: root has h2 + 1 section');
    const diagButtons = findButtons(diagTree).map(b => String(b.children[0]));
    for (const label of ['Run checks', 'Copy report'])
        ok(diagButtons.indexOf(label) !== -1, 'diagnostics: ' + label + ' button present');
    // The report serializes the last run; with the chain on demand there
    // is nothing to copy before the first run, so the button starts
    // disabled and enables only after a successful run.
    const copyBtn = findButtons(diagTree).find(b => String(b.children[0]) === 'Copy report');
    ok(copyBtn && copyBtn.attrs.disabled !== undefined,
        'diagnostics: Copy report starts disabled');
    // the chain runs on demand: rendering alone must not call diagnose
    ok(hasText(diagTree, 'not run yet'), 'diagnostics: nothing runs until Run checks is pressed');
    ok(rpcCalls.indexOf('diagnose') === -1, 'diagnostics: no diagnose call on render');
    // run the chain: the diagnose call resolves asynchronously; let the
    // microtasks run
    const diagRunBtn = findButtons(diagTree).find(b => String(b.children[0]) === 'Run checks');
    await click(diagRunBtn);
    await Promise.resolve();
    await Promise.resolve();
    ok(hasText(diagTree, 'everything checks out'), 'diagnostics: verdict banner renders');
    ok(hasText(diagTree, 'Server address'), 'diagnostics: the checks table renders');
    ok(copyBtn.disabled === false, 'diagnostics: Copy report enables after a run');

    // ===== tools.js =====
    console.log('== tools.js');
    const toolsView = loadView('tools.js');
    const toolsTree = toolsView.render();
    eq(toolsTree.tag, 'div', 'tools: root is a div');
    eq(toolsTree.children.length, 4, 'tools: root has h2 + 3 sections');
    const toolsButtons = findButtons(toolsTree).map(b => String(b.children[0]));
    for (const label of ['Run checks', 'Ping server', 'Compare addresses'])
        ok(toolsButtons.indexOf(label) !== -1, 'tools: ' + label + ' button present');
    ok(hasText(toolsTree, 'Check a domain') && hasText(toolsTree, 'Ping the server') &&
        hasText(toolsTree, 'Compare the external address'),
        'tools: the three tool sections render');
    // run the domain check tool (fill the input first, then press Run)
    const domainInput = findInputs(toolsTree).find(i => i.attrs && i.attrs.placeholder === 'youtube.com');
    domainInput.value = 'telegram.org';
    const domainBtn = findButtons(toolsTree).find(b => String(b.children[0]) === 'Run checks');
    await click(domainBtn);
    ok(await waitText(toolsTree, 'assigned profile in VPN mode'),
        'tools: the domain check renders the verdict');
    // run the Ping tool
    const pingBtn = findButtons(toolsTree).find(b => String(b.children[0]) === 'Ping server');
    await click(pingBtn);
    ok(await waitText(toolsTree, 'kz.hexbrains.com') && hasText(toolsTree, '95'),
        'tools: the ping tool renders results');
    // run the Compare tool
    const cmpBtn = findButtons(toolsTree).find(b => String(b.children[0]) === 'Compare addresses');
    await click(cmpBtn);
    ok(await waitText(toolsTree, '104.238.24.115') && hasText(toolsTree, '178.46.214.219'),
        'tools: the address compare tool renders both egresses');

    // ===== versions.js =====
    console.log('== versions.js');
    const versionsView = loadView('versions.js');
    const versionsData = await versionsView.load();
    const versionsTree = versionsView.render(versionsData);
    eq(versionsTree.tag, 'div', 'versions: root is a div');
    eq(versionsTree.children.length, 2, 'versions: root has h2 + 1 section');
    ok(hasText(versionsTree, 'TrustTunnel package') && hasText(versionsTree, 'Client package') &&
        hasText(versionsTree, 'Client binary'),
        'versions: the three version rows render');
    ok(hasText(versionsTree, '1.0.20-r1') && hasText(versionsTree, '1.1.5-r1') &&
        hasText(versionsTree, '1.1.5'),
        'versions: the backend values render');
    ok(!hasText(versionsTree, 'not installed'),
        'versions: installed packages show no fallback text');

    // ===== summary =====
    console.log('== ' + total + ' assertions, ' + failed + ' failed');
    if (failed === 0) {
        console.log('ALL VIEW TESTS PASSED');
        process.exit(0);
    }
    console.log('VIEW TEST FAILURES');
    process.exit(1);
}

// the settings Map instance: the mock records the last created map
let form_lastMap = null;
const origMap = form.Map;
form.Map = function () {
    const m = new origMap(...arguments);
    form_lastMap = m;
    return m;
};

main();
