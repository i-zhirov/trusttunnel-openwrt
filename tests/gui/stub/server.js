#!/usr/bin/env node
'use strict';

// Stub HTTP + ubus JSON-RPC server for the LuCI GUI tests.
//
// The tests drive the real LuCI views (real luci.js loader, real form.Map,
// real rpc batching) in a real headless browser, with this server standing
// in for the router:
//
//   GET  /luci-static/resources/<path>          static resources
//        (the app's htdocs overlay the pinned luci-base tree)
//   GET  /cgi-bin/luci/admin/services/trusttunnel/<view>
//                                                the page shell (header.ut
//                                                style: cbi.js, luci.js, L env)
//   POST /ubus/..., /cgi-bin/luci/admin/ubus...  JSON-RPC 2.0 frames, single
//                                                or batched (rpc.js)
//   POST /cgi-bin/luci/admin/uci/apply_rollback, apply_unchecked, confirm
//                                                the Save & Apply flow
//   GET/POST /__stub                            control endpoint: set/read
//                                                state, read recorded frames
//
// The luci.trusttunnel object is served from the backend contract goldens
// (tests/backend/goldens/*.json) so the GUI tests see byte-identical
// responses to the ones the backend contract test pins. Tests may override
// any response via the control endpoint (e.g. a broken status to exercise a
// verdict branch).
//
// Usage: node tests/gui/stub/server.js --port 8123
//        --app <repo>/packages/luci-app-trusttunnel/htdocs
//        --luci <luci-base>/htdocs
//        --goldens <repo>/tests/backend/goldens

const http = require('http');
const fs = require('fs');
const path = require('path');

function arg(name, def) {
	const i = process.argv.indexOf(name);
	return i >= 0 ? process.argv[i + 1] : def;
}

const PORT = +arg('--port', process.env.STUB_PORT || 8123);
const APP_HTDOCS = arg('--app');
const LUCI_HTDOCS = arg('--luci');
const GOLDENS = arg('--goldens');
const VIEW_DIR = 'luci-static/resources/view/trusttunnel';

// ---------------------------------------------------------------------------
// Default UCI state: mirrors root/etc/config/trusttunnel plus the Default
// routing profile the uci-defaults script seeds. All option values are
// strings, exactly as `uci show`/rpcd return them.
// ---------------------------------------------------------------------------

const defaultUci = {
	trusttunnel: {
		main: { '.type': 'main', enabled: '0', log_level: 'info' },
		endpoint: {
			'.type': 'endpoint', hostname: 'vpn.example.com', username: 'alice',
			password: 'secret', protocol: 'http2', anti_dpi: '0', post_quantum: '1',
			skip_verification: '0', certificate: '', has_ipv6: '1',
			custom_sni: '', client_random: '',
			// address is rmempty=false in the view: a realistic config
			// always carries at least one endpoint address.
			address: [ '203.0.113.10:443' ],
			routing_profile: 'Default'
		},
		network: {
			'.type': 'network', mtu: '1350', table: '880', fwmark: '0x9527',
			blackhole_on_down: '1', include_router_traffic: '0', lan_devices: ''
		},
		// Anonymous section in UCI ("config routing_profile" + option
		// name), seeded by uci-defaults exactly like the shipped default
		// config. Anonymous sections are marked with '.anonymous' in the
		// state; uci.get() renders it like rpcd does.
		cfg01: { '.type': 'routing_profile', '.anonymous': true, name: 'Default', mode: 'vpn' },
		domains: { '.type': 'domains', '.anonymous': true }
	}
};

// rpcd's uci.get() dump adds three special keys per section: '.anonymous'
// (boolean), '.type' and '.name' (the section id itself). form.js relies
// on this shape — TypedSection maps sections by s['.name'] — so the stub
// must render exactly what rpcd renders.
function rpcdUciDump(conf) {
	const out = {};
	for (const sid in conf) {
		const sec = conf[sid];
		out[sid] = {
			'.anonymous': !!sec['.anonymous'],
			'.type': sec['.type'],
			'.name': sid
		};
		for (const k in sec) {
			if (k.charAt(0) !== '.')
				out[sid][k] = sec[k];
		}
	}
	return out;
}

// ---------------------------------------------------------------------------
// State: per-method overrides (null = serve the golden) + recorded frames.
// ---------------------------------------------------------------------------

let state = {
	frames: [],
	status: null, diagnose: null, ping: null, probe: null,
	log: null, service: null, checkDomain: null, importResult: null,
	uci: JSON.parse(JSON.stringify(defaultUci)),
	goldenUci: true
};

function golden(name) {
	return JSON.parse(fs.readFileSync(path.join(GOLDENS, name), 'utf8'));
}

// Map an RPC call to the golden that pins it. The file names are the
// golden_call names from test_backend_contract.sh with ".json" appended.
function resolveData(object, method, args) {
	const a = args || {};
	switch (object) {
	case 'luci.trusttunnel':
		switch (method) {
		case 'status': return state.status || golden('status.json');
		case 'diagnose': return state.diagnose || golden('diagnose.json');
		case 'ping': return state.ping || (a.target === '8.8.8.8' ? golden('pingtarget8888.json') : golden('ping.json'));
		case 'probe': return state.probe || golden('probe.json');
		case 'log': return state.log || (a.lines === 5 ? golden('loglines5.json') : golden('log.json'));
		case 'service': return state.service || golden('serviceactionrestart.json');
		case 'check_domain':
			if (state.checkDomain)
				return state.checkDomain;
			switch (a.domain) {
			case 'telegram.org': return golden('check_domaindomaintelegram.json');
			case 'bank.example': return golden('check_domaindomainbankexam.json');
			case 'legacy.example': return golden('check_domaindomainlegacyex.json');
			default: return golden('check_domaindomain.json');
			}
		case 'import_config': return state.importResult || golden('import_configtextsampleconf.json');
		}
		break;
	case 'uci':
		return resolveUci(method, a);
	case 'luci':
		if (method === 'getFeatures')
			return { sys: {}, uci: true };
		break;
	case 'file':
		if (method === 'list')
			return { entries: [] };
		break;
	case 'session':
		if (method === 'access')
			return { access: true };
		break;
	}
	return null;
}

function resolveUci(method, a) {
	const conf = state.uci[a.config] || {};
	switch (method) {
	case 'get':
		return { values: rpcdUciDump(conf) };
	case 'add': {
		const sid = 'cfg' + Math.floor(Math.random() * 0xffffff).toString(16).padStart(6, '0');
		const values = { '.type': a.type, ...(a.values || {}) };
		if (!a.name)
			values['.anonymous'] = true;
		else
			values['.name'] = a.name;
		state.uci[a.config] = state.uci[a.config] || {};
		state.uci[a.config][sid] = values;
		return { section: sid };
	}
	case 'set':
		state.uci[a.config] = state.uci[a.config] || {};
		state.uci[a.config][a.section] = { ...(state.uci[a.config][a.section] || {}), ...(a.values || {}) };
		return {};
	case 'delete':
		state.uci[a.config] = state.uci[a.config] || {};
		delete state.uci[a.config][a.section];
		return {};
	case 'order':
		return {};
	case 'changes':
		return { changes: {} };
	case 'apply':
	case 'confirm':
		return 0;
	}
	return null;
}

// ---------------------------------------------------------------------------
// RPC handling (rpc.js frame protocol: single frame or batched array)
// ---------------------------------------------------------------------------

let rpcId = 0;

function handleFrame(frame) {
	const reply = { jsonrpc: '2.0', id: frame.id };

	if (frame.method === 'list') {
		// probeRPCBaseURL probe: only the HTTP status matters, but answer
		// with a well-formed frame anyway.
		reply.result = { 'luci.trusttunnel': {} };
		return reply;
	}

	if (frame.method !== 'call' || !Array.isArray(frame.params) || frame.params.length < 4) {
		reply.error = { code: -32600, message: 'Invalid Request' };
		return reply;
	}

	const [ , object, method, args ] = frame.params;

	state.frames.push({ id: frame.id, object, method, args });

	const data = resolveData(object, method, args);
	if (data === null) {
		reply.error = { code: -32002, message: 'Unknown method' };
		return reply;
	}

	reply.result = [ 0, data ];
	return reply;
}

function handleRpc(req, res, body) {
	let frames;
	try {
		frames = JSON.parse(body);
	}
	catch (e) {
		res.writeHead(400, { 'Content-Type': 'application/json' });
		res.end(JSON.stringify({ error: { code: -32700, message: 'Parse error' } }));
		return;
	}

	const single = !Array.isArray(frames);
	const out = single ? handleFrame(frames) : frames.map(handleFrame);

	res.writeHead(200, { 'Content-Type': 'application/json' });
	res.end(JSON.stringify(out));
}

// ---------------------------------------------------------------------------
// Control endpoint
// ---------------------------------------------------------------------------

function handleControl(req, res, body) {
	if (req.method === 'GET') {
		res.writeHead(200, { 'Content-Type': 'application/json' });
		res.end(JSON.stringify(state));
		return;
	}

	let cmd;
	try {
		cmd = JSON.parse(body);
	}
	catch (e) {
		res.writeHead(400, { 'Content-Type': 'text/plain' });
		res.end('bad json');
		return;
	}

	if (cmd.reset)
		state = { frames: [], status: null, diagnose: null,
			ping: null, probe: null, log: null, service: null, checkDomain: null,
			importResult: null, uci: JSON.parse(JSON.stringify(defaultUci)), goldenUci: true };
	else if (cmd.clearFrames)
		state.frames = [];
	else if (cmd.set)
		for (const k in cmd.set)
			state[k] = cmd.set[k];

	res.writeHead(200, { 'Content-Type': 'application/json' });
	res.end(JSON.stringify({ ok: true }));
}

// ---------------------------------------------------------------------------
// Page shell (a minimal header.ut + view.ut)
// ---------------------------------------------------------------------------

function shell(view) {
	return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>TrustTunnel | ${view}</title>
<script src="/luci-static/resources/cbi.js"></script>
<script src="/luci-static/resources/luci.js?v=1"></script>
<script>
L = new LuCI({
	media: '/luci-static',
	resource: '/luci-static/resources',
	scriptname: '/cgi-bin/luci',
	pathinfo: '',
	documentroot: '/',
	requestpath: '',
	dispatchpath: '',
	pollinterval: 1,
	ubuspath: '/ubus/',
	sessionid: '00000000000000000000000000000000',
	token: 'stub-token',
	nodespec: { title: 'TrustTunnel', satisfied: true, readonly: false },
	apply_rollback: 30,
	apply_holdoff: 1,
	apply_timeout: 2,
	apply_display: 0.2,
	rollback_token: 'stub-rollback-token'
});
</script>
</head>
<body class="lang_en" data-page="admin-services-trusttunnel-${view}">
<header>
	<a class="brand" href="/">OpenWrt</a>
	<ul class="nav" id="topmenu" style="display:none"></ul>
	<div id="indicators" class="pull-right"></div>
</header>
<div id="maincontent" class="container">
<div id="view">
	<div class="spinning">Loading view…</div>
	<script>
		L.require('ui').then(function(ui) {
			ui.instantiateView('trusttunnel/${view}');
		});
	</script>
</div>
</div>
</body>
</html>
`;
}

// ---------------------------------------------------------------------------
// Static files
// ---------------------------------------------------------------------------

function serveStatic(res, rel) {
	const roots = [ path.join(APP_HTDOCS, 'luci-static'), path.join(LUCI_HTDOCS, 'luci-static') ];

	for (const root of roots) {
		const file = path.join(root, rel);
		if (!file.startsWith(root))
			break; // no path traversal
		try {
			const data = fs.readFileSync(file);
			const ext = path.extname(file);
			const types = { '.js': 'application/javascript', '.json': 'application/json', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };
			res.writeHead(200, { 'Content-Type': types[ext] || 'application/octet-stream' });
			res.end(data);
			return;
		}
		catch (e) { /* not in this root */ }
	}

	res.writeHead(404, { 'Content-Type': 'text/plain' });
	res.end('not found');
}

// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
	const url = new URL(req.url, 'http://localhost');

	if (url.pathname === '/__stub') {
		const chunks = [];
		req.on('data', c => chunks.push(c));
		req.on('end', () => handleControl(req, res, Buffer.concat(chunks).toString('utf8')));
		return;
	}

	if (req.method === 'POST' && (url.pathname.startsWith('/ubus') || url.pathname.startsWith('/cgi-bin/luci/admin/ubus'))) {
		const chunks = [];
		req.on('data', c => chunks.push(c));
		req.on('end', () => handleRpc(req, res, Buffer.concat(chunks).toString('utf8')));
		return;
	}

	if (req.method === 'POST' && url.pathname.startsWith('/cgi-bin/luci/admin/uci/')) {
		req.resume();
		state.frames.push({ object: 'http', method: url.pathname.replace(/^\/cgi-bin\/luci/, ''), args: {} });
		if (url.pathname.endsWith('apply_rollback')) {
			res.writeHead(200, { 'Content-Type': 'application/json' });
			res.end(JSON.stringify({ token: 'stub-rollback-token' }));
		}
		else {
			res.writeHead(204);
			res.end();
		}
		return;
	}

	if (req.method === 'POST' && url.pathname.startsWith('/cgi-bin/cgi-exec')) {
		// fs.exec_direct is used by ui.changes.checkConnectivityAffected;
		// a failure is expected there (L.resolveDefault turns it into null).
		req.resume();
		res.writeHead(404, { 'Content-Type': 'text/plain' });
		res.end('not found');
		return;
	}

	if (req.method === 'GET' && url.pathname.startsWith('/luci-static/resources/')) {
		serveStatic(res, url.pathname.slice('/luci-static/'.length));
		return;
	}

	const viewMatch = /^\/cgi-bin\/luci\/admin\/services\/trusttunnel\/(status|settings|diagnostics)$/.exec(url.pathname);
	if (req.method === 'GET' && viewMatch) {
		res.writeHead(200, { 'Content-Type': 'text/html; charset=UTF-8' });
		res.end(shell(viewMatch[1]));
		return;
	}

	res.writeHead(404, { 'Content-Type': 'text/plain' });
	res.end('not found: ' + url.pathname);
});

server.listen(PORT, '127.0.0.1', () => {
	console.log('stub listening on http://127.0.0.1:' + PORT);
});
