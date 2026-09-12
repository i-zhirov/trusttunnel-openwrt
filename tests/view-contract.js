#!/usr/bin/env node
'use strict';

// Contract gate between the LuCI views, the rpcd backend and the ACL.
//
// Run from the repo root:  node tests/view-contract.js
//
// It pins two contracts that a static parse gate can hold:
//
// 1. RPC surface: every rpc.declare({object, method, params}) in the views
//    must name an object the backend registers, a method that exists on it,
//    a method granted by the ACL (read or write), and params that are a
//    subset of the backend's declared args. A typo here means the view
//    silently fails at runtime with "Command not found" from the ubus layer.
//
// 2. Diagnostics strings: every literal label/detail/hint the diagnose
//    method emits -- as pinned by the byte-exact backend contract goldens --
//    must be a key of the DIAG_TEXT map in diagnostics.js. Unmapped strings
//    would render untranslated in the Diagnostics view. Templated values
//    (addresses, versions, ping averages, ...) are exempt via the ALLOWLIST
//    below; a NEW literal string in a golden without a DIAG_TEXT entry fails
//    this gate.
//
// The goldens only cover the states they pin; a literal that no golden
// exercises (e.g. 'request failed' in the curl-failure branch of diagnose)
// cannot be caught here -- cover the state in the backend contract test
// first, then this gate sees it.

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');

const VIEW_DIR = 'packages/luci-app-trusttunnel/htdocs/luci-static/resources/view/trusttunnel';
const BACKEND = 'packages/luci-app-trusttunnel/root/usr/share/rpcd/ucode/luci.trusttunnel';
const ACL = 'packages/luci-app-trusttunnel/root/usr/share/rpcd/acl.d/luci-app-trusttunnel.json';
const GOLDENS = ['tests/backend/goldens/diagnose.json', 'tests/backend/goldens/healthy/diagnose.json'];

let failures = 0;

function fail(what) {
	console.error('::error::' + what);
	failures++;
}

function read(p) {
	return fs.readFileSync(path.join(root, p), 'utf8');
}

// --- 1. RPC surface ---------------------------------------------------------

const views = fs.readdirSync(path.join(root, VIEW_DIR)).filter(f => f.endsWith('.js'));

// rpc.declare blocks look like:
//   rpc.declare({
//       object: 'luci.trusttunnel',
//       method: 'service',
//       params: [ 'action' ],
//       expect: {}
//   });
const declares = [];
for (const view of views) {
	const src = read(path.join(VIEW_DIR, view));
	const re = /rpc\.declare\(\{([\s\S]*?)\}\)/g;
	let m;
	while ((m = re.exec(src)) !== null) {
		const block = m[1];
		const object = /\bobject:\s*'([^']+)'/.exec(block);
		const method = /\bmethod:\s*'([^']+)'/.exec(block);
		if (!object || !method) {
			fail(view + ': rpc.declare block without object/method:\n' + block);
			continue;
		}
		const params = [];
		const pm = /\bparams:\s*\[\s*([\s\S]*?)\]/.exec(block);
		if (pm) {
			const pn = /'([^']+)'/g;
			let p;
			while ((p = pn.exec(pm[1])) !== null)
				params.push(p[1]);
		}
		declares.push({ view, object: object[1], method: method[1], params });
	}
}

// Backend method registration:
//   return { 'luci.trusttunnel': { status: { args: { }, call: ... } } }
// method lines are indented with two tabs.
const backend = read(BACKEND);
const backendMethods = new Map();
const bm = /\n\t\t([A-Za-z_][A-Za-z0-9_]*): \{\n(\s*)args: \{\s*([^}]*)\}/g;
let b;
while ((b = bm.exec(backend)) !== null) {
	const args = new Set();
	const an = /([A-Za-z_][A-Za-z0-9_]*)\s*:/g;
	let a;
	while ((a = an.exec(b[3])) !== null)
		args.add(a[1]);
	backendMethods.set(b[1], args);
}

const acl = JSON.parse(read(ACL));
const aclRead = new Set(acl['luci-app-trusttunnel'].read.ubus['luci.trusttunnel'] || []);
const aclWrite = new Set(acl['luci-app-trusttunnel'].write.ubus['luci.trusttunnel'] || []);

for (const d of declares) {
	if (d.object !== 'luci.trusttunnel')
		fail(d.view + ': declares unknown rpc object "' + d.object + '" (expected luci.trusttunnel)');

	if (!backendMethods.has(d.method))
		fail(d.view + ': calls ' + d.object + '.' + d.method + ' which the backend does not register');
	else {
		const args = backendMethods.get(d.method);
		for (const p of d.params) {
			if (!args.has(p))
				fail(d.view + ': ' + d.method + ' sends param "' + p + '" which the backend args do not accept (' +
					[...args].join(', ') + ')');
		}
	}

	if (!aclRead.has(d.method) && !aclWrite.has(d.method))
		fail(d.view + ': calls ' + d.method + ' which the ACL grants neither read nor write for');
}

// --- 2. Diagnostics strings vs DIAG_TEXT ------------------------------------

const diagSrc = read(path.join(VIEW_DIR, 'diagnostics.js'));
const mapBlock = /var DIAG_TEXT = \{\n([\s\S]*?)\n\};/.exec(diagSrc);
if (!mapBlock)
	fail('diagnostics.js: cannot find the DIAG_TEXT map');
const diagKeys = new Set();
if (mapBlock) {
	const kn = /'((?:[^'\\]|\\.)*)'\s*:\s*_\s*\(/g;
	let k;
	while ((k = kn.exec(mapBlock[1])) !== null)
		diagKeys.add(k[1]);
}

// Templated values the backend concatenates into label/detail/hint. Each
// entry documents the backend expression that produces it (see the check()
// calls in luci.trusttunnel). A value that matches none of these must be a
// literal, hence a DIAG_TEXT key.
const ALLOWLIST = [
	/^\d+(?:\.\d+){2,}(?:[-+].*)?$/,                      // client version, e.g. 1.1.5
	/^(?:[0-9a-fA-F.]+|\[[0-9a-fA-F:]+\]):\d+(?:, (?:[0-9a-fA-F.]+|\[[0-9a-fA-F:]+\]):\d+)*$/, // address list
	/^\d+(?:\.\d+)? ms average$/,                         // avg_text(): ping summary
	/^.+ \(.+\)$/,                                        // pname + ' (' + pmode + ')'
	/^user .+$/,                                          // 'user ' + user
	/^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/,                     // endpoint hostname
	/^same address both ways: .+$/,                       // 'same address both ways: ' + tip
	/^.+, MTU \d+$/,                                      // dev + ', MTU ' + dev_mtu
	/^device \d+, configured \d+$/,                       // 'device ' + dev_mtu + ', configured ' + mtu_cfg
	/^default via .+$/,                                   // 'default via ' + dev
	/^tunnel .+, direct .+$/                              // 'tunnel ' + tip + ', direct ' + dip
];

const seen = new Set();
for (const g of GOLDENS) {
	const data = JSON.parse(read(g));
	for (const c of data.checks || []) {
		for (const field of ['label', 'detail', 'hint']) {
			const s = c[field];
			if (!s || seen.has(s))
				continue;
			seen.add(s);
			if (diagKeys.has(s))
				continue;
			if (ALLOWLIST.some(re => re.test(s)))
				continue;
			fail('diagnostics.js: "' + s + '" (from ' + g + ' ' + field + ') is not a DIAG_TEXT key');
		}
	}
}

process.exit(failures ? 1 : 0);
