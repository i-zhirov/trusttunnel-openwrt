'use strict';

import { popen, readfile, writefile, access, unlink, stat, mkdir, chmod } from 'fs';
import { rand, srand } from 'math';

// The tmp_path() helper below uses rand(), which lives in the math module,
// not in the ucode core. The module is declared in LUCI_DEPENDS as
// +ucode-mod-math; without the import tmp_path() throws at runtime and the
// config import and the domain check break with it.
srand(time());

const LIBDIR = '/usr/libexec/trusttunnel';
const OUTDIR = '/var/etc/trusttunnel';
const RECORDS = OUTDIR + '/settings.tsv';
const CLIENT = '/opt/trusttunnel_client/trusttunnel_client';
const RELEASE_URL = 'https://api.github.com/repos/i-zhirov/trusttunnel-openwrt/releases/latest';
const VERSION_CACHE = '/var/cache/trusttunnel/release.json';
// Six hours between update checks: four requests per day per router, a
// vanishing fraction of the 60 unauthenticated requests GitHub allows per
// hour. The status page polls every ten seconds, so without a disk cache a
// single open browser would exhaust the limit in minutes.
const RELEASE_TTL = 21600;

// Run a command and return { code, out } with stderr merged into stdout.
// Merging matters wherever the error text is itself the result (service
// control, log, import).
function sh(cmd) {
	let p = popen(cmd + ' 2>&1');
	if (!p)
		return { code: 127, out: '' };

	let out = p.read('all') ?? '';
	let code = p.close() ?? 127;

	return { code: code, out: out };
}

// Run a command and return stdout only. Required wherever the output is
// parsed: warnings on stderr would otherwise become data.
function sh_out(cmd) {
	let p = popen(cmd + ' 2>/dev/null');
	if (!p)
		return { code: 127, out: '' };

	let out = p.read('all') ?? '';
	let code = p.close() ?? 127;

	return { code: code, out: out };
}

// Shell single-quote escaping: close the quote, insert the escaped quote,
// reopen.
function shq(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

// An unpredictable name in the world-writable temp directory. These files
// are written by root into /tmp, and at least one caller (import_config)
// puts the endpoint password there in the clear; a fixed name plus default
// permissions would make the file readable and replaceable for any local
// unprivileged process in the window between writing and reading.
function tmp_path(prefix) {
	return sprintf('/tmp/.tt-%s-%08x%04x', prefix, time(), rand() % 65536);
}

// Write a secret into a fresh temp file with mode 0600 in one place, so no
// caller can forget the permissions after creating a file with a secret in
// it.
function write_secret_tmp(prefix, data) {
	let path = tmp_path(prefix);
	writefile(path, data);
	chmod(path, 384); // 0600
	return path;
}

// Compare version strings by numeric components. String comparison is wrong
// here: "1.0.10" sorts before "1.0.9", so an update would silently never be
// offered on every tenth release. A leading "v" and a "-rN" package suffix
// are dropped before comparing. Components that do not start with a digit
// count as 0. Returns >0 when a is newer, <0 when older, 0 when equal.
function vercmp(a, b) {
	function parts(s) {
		s = replace('' + s, /^[vV]/, '');
		s = replace(s, /-.*$/, '');
		let out = [];
		for (let p in split(s, '.')) {
			let m = match(p, /^([0-9]+)/);
			push(out, m ? +m[1] : 0);
		}
		return out;
	}

	let pa = parts(a), pb = parts(b);
	let n = length(pa) > length(pb) ? length(pa) : length(pb);

	for (let i = 0; i < n; i++) {
		let x = i < length(pa) ? pa[i] : 0;
		let y = i < length(pb) ? pb[i] : 0;
		if (x != y)
			return x > y ? 1 : -1;
	}

	return 0;
}

// Read the UCI value at the given dotted path. The output is trimmed.
function uciget(path) {
	let r = sh_out('uci -q get ' + shq(path));
	return trim(r.out);
}

// Parse the records TSV (section.option<TAB>value, one line per list
// value) into a key -> array map. Lines without a tab separator are
// skipped.
function records() {
	let raw = readfile(RECORDS);
	let out = {};

	if (raw == null)
		return out;

	for (let line in split(raw, '\n')) {
		let t = index(line, '\t');
		if (t < 0)
			continue;

		let key = substr(line, 0, t);
		let value = substr(line, t + 1);
		if (!(key in out))
			out[key] = [];
		push(out[key], value);
	}

	return out;
}

// First value for a key, or the default when the key is absent or its
// first value is empty.
function first(rec, key, dflt) {
	let v = rec[key];
	return length(v) && length(v[0]) ? v[0] : dflt;
}

// The host part of an endpoint address: "host:port", "[v6]:port" or a bare
// host.
function endpoint_host(s) {
	s = trim('' + s);

	if (substr(s, 0, 1) == '[') {
		let end = index(s, ']');
		return end > 1 ? substr(s, 1, end - 1) : s;
	}

	let c = index(s, ':');
	return c > 0 ? substr(s, 0, c) : s;
}

// Parse the summary of a `ping -q` run into a result object. The host is
// the address that was pinged, not the one in the output. Without a
// round-trip line (total loss, unreachable host) the timing fields are
// null and the loss is 100.
function parse_ping(host, output) {
	let res = {
		host: host, sent: 0, received: 0,
		loss: 100, min: null, avg: null, max: null
	};

	let m = match(output, /([0-9]+) packets transmitted, ([0-9]+) packets received, ([0-9]+)% packet loss/);
	if (m) {
		res.sent = +m[1];
		res.received = +m[2];
		res.loss = +m[3];
	}

	m = match(output, /round-trip min\/avg\/max = ([0-9.]+)\/([0-9.]+)\/([0-9.]+)/);
	if (m) {
		res.min = +m[1];
		res.avg = +m[2];
		res.max = +m[3];
	}

	return res;
}

// Ask the routing helper about the applied kernel state. Returns a flat
// object with the device name (when the helper reports one) and the four
// presence flags; everything is false/empty when the records file is
// absent or the helper fails.
function routing_status() {
	let out = { device: '', device_up: false, rule: false, table: false, nft: false };

	if (access(RECORDS) == null)
		return out;

	let r = sh(LIBDIR + '/routing status ' + shq(RECORDS) + ' ' + shq(OUTDIR));

	for (let line in split(r.out, '\n')) {
		line = trim(line);
		if (line == 'device up')
			out.device_up = true;
		else if (line == 'rule present')
			out.rule = true;
		else if (line == 'table present')
			out.table = true;
		else if (line == 'nft present')
			out.nft = true;
		else if (match(line, /^client device /))
			out.device = trim(substr(line, 14));
	}

	return out;
}

// One diagnose check.
function check(group, label, status, detail, hint) {
	return { group: group, label: label, status: status, detail: detail, hint: hint };
}

// The "X ms average" phrasing for the reachability check, from a ping
// summary.
function avg_text(output) {
	let m = match(output, /round-trip min\/avg\/max = ([0-9.]+)\/([0-9.]+)\/([0-9.]+)/);
	return m ? m[2] + ' ms average' : 'no reply';
}

return {
	'luci.trusttunnel': {
		status: {
			args: { },
			call: function() {
				let rec = records();
				let rs = routing_status();
				let pname = first(rec, 'routing_profile.name', '');
				let pmode = first(rec, 'routing_profile.mode', '');

				let running = sh('/etc/init.d/trusttunnel running').code == 0;

				return {
					enabled: uciget('trusttunnel.main.enabled') == '1',
					running: running,
					device: length(rs.device) ? rs.device : null,
					device_up: rs.device_up,
					rule: rs.rule,
					table: rs.table,
					nft: rs.nft,
					endpoint_hostname: first(rec, 'endpoint.hostname', ''),
					addresses: rec['endpoint.address'] ?? [],
					client_installed: access(CLIENT) ? true : false,
					routing_profile: pname,
					// Only meaningful when a profile is assigned; without
					// one the effective mode is the legacy general.
					routing_mode: pmode,
					// The effective client vpn_mode: selective for a
					// bypass-mode profile, general otherwise.
					vpn_mode: pmode == 'bypass' ? 'selective' : 'general'
				};
			}
		},

		service: {
			args: { action: 'restart' },
			call: function(req) {
				let action = req.args?.action ?? 'restart';

				if (action != 'start' && action != 'stop' &&
				    action != 'restart' && action != 'reload')
					return { error: 'unsupported action' };

				let r = sh('/etc/init.d/trusttunnel ' + action);

				// A start is only a start once the service answers
				// "running": procd forks the client asynchronously, so the
				// init script may have exited 0 before anything came up.
				if (action == 'start') {
					sleep(1);
					if (sh('/etc/init.d/trusttunnel running').code != 0)
						return { code: 1, output: r.out, not_running: true };
				}

				return { code: r.code, output: r.out };
			}
		},

		ping: {
			args: { target: '' },
			call: function(req) {
				let target = trim(req.args?.target ?? '');
				let hosts = [];

				if (length(target)) {
					push(hosts, target);
				} else {
					let rec = records();
					let addrs = rec['endpoint.address'] ?? [];

					if (!length(addrs))
						return { error: 'no endpoint address configured' };

					for (let a in addrs)
						push(hosts, endpoint_host(a));
				}

				let results = [];
				for (let h in hosts) {
					let r = sh_out('ping -c 4 -W 2 -q ' + shq(h));
					push(results, parse_ping(h, r.out));
				}

				return { results: results };
			}
		},

		probe: {
			args: { },
			call: function() {
				let rs = routing_status();

				if (!length(rs.device))
					return {
						tunnel: { error: 'the client has not created a tunnel device yet' },
						direct: { error: 'not attempted' }
					};

				let via = sh_out('curl -fsS --max-time 8 --interface ' + shq(rs.device) + ' https://api.ipify.org');
				let plain = sh_out('curl -fsS --max-time 8 https://api.ipify.org');

				let tunnel = via.code == 0 ? { ip: trim(via.out) } : { error: length(trim(via.out)) ? trim(via.out) : 'request failed' };
				let direct = plain.code == 0 ? { ip: trim(plain.out) } : { error: length(trim(plain.out)) ? trim(plain.out) : 'request failed' };

				return { tunnel: tunnel, direct: direct };
			}
		},

		check_domain: {
			args: { domain: '' },
			call: function(req) {
				let raw = trim(req.args?.domain ?? '');

				if (!length(raw))
					return { error: 'domain is required' };

				let rec = records();
				let pname = first(rec, 'routing_profile.name', '');
				let pmode = first(rec, 'routing_profile.mode', '');
				let list_key;

				// The effective exclusion list: with a profile assigned its
				// rules decide (in vpn mode the bypass rules go direct, in
				// bypass mode the VPN rules go through the tunnel); without
				// one the legacy flat "do not bypass" list applies.
				if (length(pname))
					list_key = pmode == 'bypass' ? 'routing_profile.vpn_rules' : 'routing_profile.bypass_rules';
				else
					list_key = 'domains.direct';

				let lc_raw = lc(raw);
				let in_list = false;

				for (let d in (rec[list_key] ?? [])) {
					let rule = lc(trim(d));
					if (rule == lc_raw || substr(lc_raw, -(length(rule) + 1)) == '.' + rule) {
						in_list = true;
						break;
					}
				}

				if (length(pname) && pmode == 'bypass')
					return {
						domain: raw, normalized: lc_raw,
						verdict: in_list ? 'tunnel' : 'direct',
						reason: in_list
							? "listed in the profile's VPN rules; the client routes it through the tunnel"
							: 'the assigned profile is in bypass mode; everything else stays direct'
					};

				if (length(pname))
					return {
						domain: raw, normalized: lc_raw,
						verdict: in_list ? 'direct' : 'tunnel',
						reason: in_list
							? "listed in the profile's bypass rules; the client sends it out directly"
							: 'the assigned profile is in VPN mode; everything else goes through the tunnel'
					};

				return {
					domain: raw, normalized: lc_raw,
					verdict: in_list ? 'direct' : 'tunnel',
					reason: in_list
						? 'listed in the "do not bypass" list; the client sends it out by SNI'
						: 'all LAN traffic goes through the tunnel (full-tunnel mode)'
				};
			}
		},

		log: {
			args: { lines: 100 },
			call: function(req) {
				let n = req.args?.lines ?? 100;
				let r = sh_out('logread -e trusttunnel | tail -n ' + n);
				let o = trim(r.out);

				return { lines: length(o) ? split(o, '\n') : [ '' ] };
			}
		},

		diagnose: {
			args: { },
			call: function() {
				let rec = records();
				let rs = routing_status();
				// The routing checks report "absent" only while the config
				// is applied; without the records file they are skipped.
				let applied = access(RECORDS) != null;
				let checks = [];

				let host = first(rec, 'endpoint.hostname', '');
				let user = first(rec, 'endpoint.username', '');
				let pass = first(rec, 'endpoint.password', '');
				let addrs = rec['endpoint.address'] ?? [];
				let pname = first(rec, 'routing_profile.name', '');
				let pmode = first(rec, 'routing_profile.mode', '');
				let mtu_cfg = first(rec, 'network.mtu', '1350');
				let table = first(rec, 'network.table', '880');

				// --- Configuration ---

				if (length(addrs))
					push(checks, check('config', 'Endpoint address', 'ok', join(', ', addrs), ''));
				else
					push(checks, check('config', 'Endpoint address', 'fail', 'not set',
						'Fill in the address on the Settings page, or import the server config.'));

				if (length(user) && length(pass))
					push(checks, check('config', 'Credentials', 'ok', 'user ' + user, ''));
				else
					push(checks, check('config', 'Credentials', 'fail', 'not set',
						'Both the user name and the password are required.'));

				if (length(host))
					push(checks, check('config', 'TLS host name', 'ok', host, ''));
				else
					push(checks, check('config', 'TLS host name', 'warn', 'not set',
						'Without it the TLS session uses the bare address, which many servers reject.'));

				if (length(pname))
					push(checks, check('config', 'Routing profile', 'ok', pname + ' (' + pmode + ')', ''));
				else
					push(checks, check('config', 'Routing profile', 'warn', 'none — legacy full-tunnel mode',
						'Assign a routing profile on the Settings page to control what goes through the tunnel.'));

				// --- Prerequisites ---

				let cl = access(CLIENT);

				if (cl) {
					let ver = sh_out(CLIENT + ' --version');
					let vm = match(ver.out, /[0-9]+\.[0-9]+\.[0-9]+[^ \t\n]*/);
					push(checks, check('prereq', 'TrustTunnel client', 'ok', vm ? vm[0] : trim(ver.out), ''));
				} else {
					push(checks, check('prereq', 'TrustTunnel client', 'fail', 'not installed',
						'The client is a dependency of the package; reinstall trusttunnel-client.'));
				}

				if (access('/dev/net/tun'))
					push(checks, check('prereq', 'tun device', 'ok', '/dev/net/tun present', ''));
				else
					push(checks, check('prereq', 'tun device', 'fail', 'missing', 'Install kmod-tun.'));

				// --- Service ---

				let enabled = uciget('trusttunnel.main.enabled') == '1';
				let running = sh('/etc/init.d/trusttunnel running').code == 0;

				if (enabled)
					push(checks, check('service', 'Enabled', 'ok', 'yes', ''));
				else
					push(checks, check('service', 'Enabled', 'warn', 'no',
						'Turn on Enable on the Settings page, then press Start.'));

				if (running)
					push(checks, check('service', 'Running', 'ok', 'yes', ''));
				else
					push(checks, check('service', 'Running', 'fail', 'no',
						'Press Start and read the client log below.'));

				// --- Kernel ---

				// The device name comes from the routing helper; without a
				// recorded device there is nothing to inspect and the
				// device-bound checks are skipped as a group.
				let dev = rs.device;
				let dev_sys = length(dev) ? '/sys/class/net/' + dev : '';

				if (!length(dev)) {
					push(checks, check('kernel', 'Tunnel device', running ? 'fail' : 'skip', 'the client has not created one',
						'The device belongs to the client, not to this package. Read the client log below.'));
				} else if (access(dev_sys) == null) {
					push(checks, check('kernel', 'Tunnel device', 'fail', 'the client has not created one',
						'The device belongs to the client, not to this package. Read the client log below.'));
				} else {
					let dev_mtu = trim(readfile(dev_sys + '/mtu') ?? '');
					push(checks, check('kernel', 'Tunnel device', 'ok',
						dev + ', MTU ' + dev_mtu, ''));

					// The MTU check only reports a mismatch; a matching
					// value adds no entry.
					if (length(dev_mtu) && dev_mtu != mtu_cfg)
						push(checks, check('kernel', 'MTU matches settings', 'warn',
							'device ' + dev_mtu + ', configured ' + mtu_cfg,
							'Restart the service so the client picks up the configured value.'));

					let route = sh_out('ip route show table ' + table);
					if (index(route.out, 'dev ' + dev) >= 0)
						push(checks, check('kernel', 'Route attached to the device', 'ok',
							'default via ' + dev, ''));
					else
						push(checks, check('kernel', 'Route attached to the device', 'fail', 'not attached',
							'Marked traffic falls into the killswitch instead of the tunnel. Restart the service.'));

					let carrier = trim(readfile(dev_sys + '/carrier') ?? '');
					if (carrier == '1')
						push(checks, check('kernel', 'Tunnel carrier', 'ok', 'up', ''));
					else
						push(checks, check('kernel', 'Tunnel carrier', 'warn', 'no carrier',
							'The device exists but the client has not established the tunnel yet. This is the client side, not the routing — read the client log.'));
				}

				if (rs.rule)
					push(checks, check('kernel', 'Routing rule', 'ok', 'present', ''));
				else
					push(checks, check('kernel', 'Routing rule', applied ? 'fail' : 'skip', 'absent', ''));

				if (rs.table)
					push(checks, check('kernel', 'Routing table', 'ok', 'present', ''));
				else
					push(checks, check('kernel', 'Routing table', applied ? 'fail' : 'skip', 'absent', ''));

				if (rs.nft)
					push(checks, check('kernel', 'nftables table', 'ok', 'present', ''));
				else
					push(checks, check('kernel', 'nftables table', applied ? 'fail' : 'skip', 'absent', ''));

				let fw = sh_out('nft list ruleset');
				if (index(fw.out, 'trusttunnel') >= 0)
					push(checks, check('kernel', 'Firewall zone', 'ok', 'loaded in fw4', ''));
				else
					push(checks, check('kernel', 'Firewall zone', 'warn', 'not in the live ruleset',
						'Run /etc/init.d/firewall reload — traffic into the tunnel is dropped without the zone.'));

				// --- Network ---

				if (length(addrs)) {
					let first_addr = endpoint_host(addrs[0]);
					let pr = sh_out('ping -c 2 -W 2 ' + shq(first_addr));

					if (pr.code == 0)
						push(checks, check('network', 'Endpoint reachable', 'ok',
							avg_text(pr.out), ''));
					else
						push(checks, check('network', 'Endpoint reachable', 'fail',
							'no reply from ' + first_addr,
							'Check the address, and that the router itself has internet access.'));
				}

				if (running && length(dev)) {
					let via = sh_out('curl -fsS --max-time 8 --interface ' + shq(dev) + ' https://api.ipify.org');
					let plain = sh_out('curl -fsS --max-time 8 https://api.ipify.org');
					let tip = trim(via.out);
					let dip = trim(plain.out);

					if (via.code == 0 && plain.code == 0 && tip == dip)
						push(checks, check('network', 'Traffic goes through the tunnel', 'fail',
							'same address both ways: ' + tip,
							'The tunnel is up but traffic is not using it.'));
					else if (via.code == 0 && plain.code == 0)
						push(checks, check('network', 'Traffic goes through the tunnel', 'ok',
							'tunnel ' + tip + ', direct ' + dip, ''));
					else
						push(checks, check('network', 'Traffic goes through the tunnel', 'fail',
							length(tip) ? tip : 'request failed',
							'A request bound to the device can fail even on a healthy tunnel, because the default route lives in the marked table. Judge by a LAN client instead.'));
				}

				let counts = { ok: 0, warn: 0, fail: 0, skip: 0 };
				for (let c in checks)
					counts[c.status]++;

				let verdict = counts.fail > 0 ? 'fail' : (counts.warn > 0 ? 'warn' : 'ok');

				return { checks: checks, counts: counts, verdict: verdict };
			}
		},

		versions: {
			args: { refresh: false },
			call: function(req) {
				let refresh = req.args?.refresh ?? false;
				let res = {
					client: null, package: null, latest: null,
					update_available: false, checked_at: null,
					stale: false, ahead: false
				};

				let cv = sh_out(CLIENT + ' --version');
				if (cv.code == 0) {
					let m = match(cv.out, /[0-9]+\.[0-9]+\.[0-9]+[^ \t\n]*/);
					if (m)
						res.client = m[0];
				}

				let apk = sh_out('apk list -I luci-app-trusttunnel');
				if (apk.code == 0) {
					let m = match(apk.out, /luci-app-trusttunnel-([^ \t\n]+)/);
					if (m)
						res.package = m[1];
				}
				if (res.package == null) {
					let opkg = sh_out('opkg info luci-app-trusttunnel');
					let m = match(opkg.out, /Version: ([^ \t\n]+)/);
					if (m)
						res.package = m[1];
				}

				let now = time();
				let cache = null;
				let cached = readfile(VERSION_CACHE);

				if (cached != null) {
					// A corrupted or foreign cache file must not crash the
					// update check: json() throws on malformed input.
					let j = null;
					try { j = json(cached); } catch (e) { }
					if (type(j) == 'object')
						cache = j;
				}

				let fresh = cache != null &&
					(type(cache.checked_at) == 'int' || type(cache.checked_at) == 'double') &&
					(now - cache.checked_at) < RELEASE_TTL;

				// A fresh cache is authoritative unless the installed
				// package is already newer than the cached tag: then the
				// cache is behind and must be refreshed regardless.
				let behind = res.package != null && cache != null &&
					type(cache.tag) == 'string' && vercmp(cache.tag, res.package) < 0;

				if (!refresh && fresh && !behind && cache != null && type(cache.tag) == 'string') {
					res.latest = cache.tag;
					res.checked_at = cache.checked_at;
				} else {
					let r = sh_out('curl -fsS --max-time 15 ' + RELEASE_URL);

					if (r.code == 0) {
						// The endpoint is not a JSON API: any non-JSON body
						// (an error page, a proxy notice) means "no answer",
						// not a crash.
						let j = null;
						try { j = json(r.out); } catch (e) { }
						let tag = type(j) == 'object' ? j.tag_name : null;

						if (type(tag) == 'string' && length(tag)) {
							res.latest = tag;
							res.checked_at = now;
							res.stale = false;

							mkdir('/var/cache');
							mkdir('/var/cache/trusttunnel');
							if (!writefile(VERSION_CACHE, sprintf('%J', { tag: tag, checked_at: now })))
								sh('/usr/bin/logger -t trusttunnel "failed to write the update cache"');
						}
					} else if (cache != null && type(cache.tag) == 'string') {
						// Network failure: fall back to the cached answer
						// with its original timestamp, marked stale. The
						// cache file is left untouched — a failed check
						// does not refresh it.
						res.latest = cache.tag;
						res.checked_at = cache.checked_at;
						res.stale = true;
					}
				}

				if (res.package != null && res.latest != null) {
					let cmp = vercmp(res.latest, res.package);
					res.update_available = cmp > 0;
					res.ahead = cmp < 0;
				}

				return res;
			}
		},

		import_config: {
			args: { text: '' },
			call: function(req) {
				let text = req.args?.text ?? '';

				if (!length(trim(text)))
					return { error: 'configuration text is empty' };

				if (access('/opt/trusttunnel_client/setup_wizard') == null)
					return { error: 'setup_wizard is not installed; reinstall the trusttunnel-client package' };

				let settings = tmp_path('wizard');
				let input = null;
				let r;

				if (match(text, /^tt:\/\//)) {
					r = sh('/opt/trusttunnel_client/setup_wizard --mode non-interactive --deeplink ' +
						shq(text) + ' --settings ' + shq(settings));
				} else {
					input = write_secret_tmp('config', text);
					r = sh('/opt/trusttunnel_client/setup_wizard --mode non-interactive --endpoint_config ' +
						shq(input) + ' --settings ' + shq(settings));
				}

				let produced = readfile(settings);
				if (input != null)
					unlink(input);
				unlink(settings);

				if (r.code != 0 || produced == null || !length(trim(produced))) {
					// A failed wizard run ends in a Rust panic; filter the
					// noise so the message names the actual problem.
					let msg = [];
					for (let line in split(r.out, '\n')) {
						if (match(line, /^thread .*panicked at/) ||
						    match(line, /^note: /) ||
						    match(line, /^Aborted/))
							continue;
						if (length(trim(line)))
							push(msg, trim(line));
					}
					return { error: length(msg) ? join(msg, ' ') : 'setup_wizard failed' };
				}

				// Every [endpoint] field the server can hand out is parsed
				// by shape: a quoted string, an array in brackets, or a
				// boolean. Losing a field on import is not cosmetics — an
				// anti-scan server accepts only clients with the matching
				// client_random prefix.
				function unquote(v) {
					let m = match(v, /^"(.*)"$/);
					return m ? m[1] : null;
				}
				function unlist(v) {
					let m = match(v, /^\[(.*)\]$/);
					if (!m)
						return null;
					let out = [];
					for (let a in split(m[1], ',')) {
						a = replace(trim(a), /"/g, '');
						if (length(a))
							push(out, a);
					}
					return out;
				}
				function unbool(v) {
					return v == 'true' ? '1' : (v == 'false' ? '0' : null);
				}

				let res = { addresses: [], dns_upstreams: [] };

				for (let line in split(produced, '\n')) {
					let kv = match(line, /^ *([a-z0-9_]+) *= *(.*)$/);
					if (!kv)
						continue;

					let k = kv[1], v = trim(kv[2]), s;

					switch (k) {
					case 'hostname': case 'username': case 'password':
					case 'certificate': case 'custom_sni': case 'client_random':
						s = unquote(v);
						if (s != null && length(s))
							res[k] = s;
						break;
					case 'upstream_protocol':
						s = unquote(v);
						if (s == 'http2' || s == 'http3')
							res.protocol = s;
						break;
					case 'has_ipv6': case 'skip_verification': case 'anti_dpi':
						s = unbool(v);
						if (s != null)
							res[k] = s;
						break;
					case 'addresses': case 'dns_upstreams':
						s = unlist(v);
						if (s != null)
							res[k] = s;
						break;
					}
				}

				// A run that produced a file but no recognizable field is
				// a wizard/schema mismatch, not a valid import.
				if (!length(res.hostname) && !length(res.username) &&
				    !length(res.password) && !length(res.certificate) &&
				    !length(res.addresses))
					return { error: 'setup_wizard produced no recognisable endpoint fields' };

				return res;
			}
		}
	}
};
