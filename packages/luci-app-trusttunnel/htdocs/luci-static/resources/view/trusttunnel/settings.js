'use strict';

'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require dom';

// All settings live in one UCI config, so the page presents them as a
// single tabbed map: each section turns into a tab, and switching tabs is
// pure browser-side work, no router round-trip.
//
// The tabs are grouped by what the fields mean to the user rather than by
// the UCI layout: General (service state and the ACTIVE server), Server
// (the saved servers — repeatable endpoint sections, one selected as
// active on General; each server carries its own Connection/Security
// settings and routing profile), Routing profiles and Advanced
// (networking internals).
var callImport = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'import_config',
	params: [ 'text' ]
});

var callStatus = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'status'
});

var callPing = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'ping',
	params: [ 'target' ]
});

var callCheckDomain = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'check_domain',
	params: [ 'domain' ]
});

// Read-only one-liner for the General tab; the full verdict banner with
// Start/Stop lives on the Status page.
function statusSummary(st) {
	if (!st)
		return _('Status unavailable');

	if (!st.client_installed)
		return _('The TrustTunnel client is not installed');

	if (!st.running)
		return st.enabled ? _('The service is not running') : _('The service is off');

	// Proxy mode has no tun device: the listener state takes its place.
	if (st.mode === 'proxy') {
		if (!st.listener_up)
			return _('Connecting to the server…');

		var addr = st.proxy_address || '';
		var head = addr ? _('Proxy listening on %s').format(addr) : _('Proxy listening');

		if (st.routing_profile)
			return _('%s — profile %s').format(head, st.routing_profile);

		return head;
	}

	if (!st.device_up)
		return _('Connecting to the server…');

	var head = st.device ? _('Running on %s').format(st.device) : _('Running');

	if (st.routing_profile)
		return _('%s — profile %s').format(head, st.routing_profile);

	return head;
}

// Header and rows for the rule preview table, mirroring the Check a
// domain tool: the rule itself, a verdict badge and the backend's reason.
function verdictHead() {
	return E('tr', { 'class': 'cbi-section-table-row' }, [
		E('th', { 'class': 'cbi-section-table-cell' }, _('Rule')),
		E('th', { 'class': 'cbi-section-table-cell' }, _('Verdict')),
		E('th', { 'class': 'cbi-section-table-cell' }, _('Why'))
	]);
}

function verdictRow(rule, res) {
	var cell;

	if (res.error) {
		cell = E('td', { 'class': 'cbi-section-table-cell' }, _('not checked'));
	}
	else {
		var tunnel = res.verdict && res.verdict.indexOf('tunnel') === 0;

		cell = E('td', { 'class': 'cbi-section-table-cell' },
			E('span', { 'style': 'font-weight:bold; color:' + (tunnel ? '#2e7d32' : '#c62828') + ';' },
				tunnel ? _('through the tunnel') : _('direct')));
	}

	return E('tr', { 'class': 'cbi-section-table-row' }, [
		E('td', { 'class': 'cbi-section-table-cell' }, E('code', rule)),
		cell,
		E('td', { 'class': 'cbi-section-table-cell' }, res.error || res.reason || '')
	]);
}

return view.extend({
	load: function() {
		// The network config feeds the LAN device hint on the Advanced
		// tab; the status call feeds the Service line on the General tab.
		// A failure of either must not take the whole settings page down.
		return Promise.all([
			uci.load('trusttunnel'),
			uci.load('network').catch(function() { return null; }),
			callStatus().catch(function() { return null; })
		]);
	},

	// The section id of the ACTIVE server: the endpoint section whose name
	// matches main.endpoint. With several saved servers the literal
	// "endpoint" name would be just one of them, so the import target is
	// always resolved through the selection.
	activeServerSection: function() {
		var active = uci.get('trusttunnel', 'main', 'endpoint');
		var servers = uci.sections('trusttunnel', 'endpoint') || [];

		for (var i = 0; i < servers.length; i++)
			if (servers[i].name === active)
				return servers[i]['.name'];

		// A stale or empty selection falls back to the first server, so
		// the import has a target even before the user picked one.
		return servers.length ? servers[0]['.name'] : null;
	},

	handleImport: function(ev, section_id) {
		var ta = E('textarea', {
			'style': 'width:100%', 'rows': 12,
			'placeholder': _('Paste the configuration your server generated')
		});

		// The imported values land in the server whose Import button was
		// pressed (section_id); a handler invoked without one falls back
		// to the active server. Computed once here so the promise chain
		// below does not need a `this`.
		var target = section_id || this.activeServerSection();

		// import_config hands the text to the vendor's setup_wizard binary
		// and parses its output, which takes a moment: while it runs, the
		// Import button is disabled and shows a spinner, so a slow answer
		// does not look like a dead click (nor can it double-submit).
		var importBtn = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'click': ui.createHandlerFn(this, function() {
				var restore = function() {
					importBtn.disabled = false;
					dom.content(importBtn, _('Import'));
				};

				importBtn.disabled = true;
				dom.content(importBtn, E('span', { 'class': 'spinning' }, _('Importing…')));

				return callImport(ta.value).then(function(res) {
					if (res.error) {
						ui.addNotification(null, E('p', {}, res.error), 'danger');
						restore();
						return;
					}

					if (!target) {
						restore();
						ui.addNotification(null, E('p', {}, _('Save a server first — the import needs a place to land.')), 'danger');
						return;
					}

					// Every imported value is applied through the
					// pending save below: nothing is written until
					// the user presses Save & Apply.
					var fields = {
						hostname: 'hostname', username: 'username', password: 'password',
						certificate: 'certificate', custom_sni: 'custom_sni',
						client_random: 'client_random', protocol: 'protocol',
						anti_dpi: 'anti_dpi', has_ipv6: 'has_ipv6',
						skip_verification: 'skip_verification'
					};

					Object.keys(fields).forEach(function(k) {
						if (res[k] != null)
							uci.set('trusttunnel', target, fields[k], res[k]);
					});

					if (res.addresses && res.addresses.length)
						uci.set('trusttunnel', target, 'address', res.addresses);
					if (res.dns_upstreams && res.dns_upstreams.length)
						uci.set('trusttunnel', target, 'dns_upstream', res.dns_upstreams);

					// A server needs a name to be selectable; the imported
					// hostname is the natural default.
					if (!uci.get('trusttunnel', target, 'name') && res.hostname)
						uci.set('trusttunnel', target, 'name', res.hostname);

					// An empty or stale active-server reference is healed:
					// the import makes this server the active one. A valid
					// selection is never overridden.
					var sel = uci.get('trusttunnel', 'main', 'endpoint');
					var selected = uci.sections('trusttunnel', 'endpoint').some(function(s) {
						return s.name === sel;
					});

					if (!selected && uci.get('trusttunnel', target, 'name'))
						uci.set('trusttunnel', 'main', 'endpoint', uci.get('trusttunnel', target, 'name'));

					uci.save();
					ui.hideModal();
					ui.addNotification(null, E('p', {}, _('Import applied. Review the fields, then press Save & Apply.')), 'info');
					window.setTimeout(function() {
						location.reload();
					}, 800);
				}).catch(function(e) {
					ui.addNotification(null, E('p', {}, e.message || String(e)), 'danger');
					restore();
				});
			})
		}, _('Import'));

		// The modal body mirrors a form section: an explanation, the paste
		// target, and a right-aligned action row.
		var body = E('div', {}, [
			E('p', {}, _('Paste the configuration file text or a tt:// link your server handed out. Nothing is written until you press Save & Apply.')),
			ta
		]);
		var actions = E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')),
			' ',
			importBtn
		]);

		ui.showModal(_('Import server settings'), [ body, actions ]);
	},

	handleTest: function() {
		var box = E('div', {}, [
			E('p', { 'class': 'spinning' }, _('Pinging…'))
		]);

		ui.showModal(_('Test connection'), [
			E('p', {}, _('Loss and round-trip time for every configured address. The saved settings are used, so press Save & Apply first.')),
			box,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
			])
		]);

		callPing('').then(function(res) {
			if (res.error) {
				dom.content(box, E('p', res.error));
				return;
			}

			var rows = [
				E('tr', { 'class': 'cbi-section-table-row' }, [
					E('th', { 'class': 'cbi-section-table-cell' }, _('Host')),
					E('th', { 'class': 'cbi-section-table-cell' }, _('Loss')),
					E('th', { 'class': 'cbi-section-table-cell' }, _('min / avg / max'))
				])
			];

			(res.results || []).forEach(function(r) {
				rows.push(E('tr', { 'class': 'cbi-section-table-row' }, [
					E('td', { 'class': 'cbi-section-table-cell' }, r.host),
					E('td', { 'class': 'cbi-section-table-cell' }, r.loss + '%'),
					E('td', { 'class': 'cbi-section-table-cell' },
						r.avg === null ? '—' : r.min + ' / ' + r.avg + ' / ' + r.max + ' ms')
				]));
			});

			dom.content(box, E('table', { 'class': 'cbi-section-table' }, rows));
		}).catch(function(e) {
			dom.content(box, E('p', e.message || String(e)));
		});
	},

	handlePreview: function(ev, section_id) {
		var profile = null;
		var secs = this._profiles || [];

		for (var i = 0; i < secs.length; i++)
			if (secs[i]['.name'] === section_id) {
				profile = secs[i];
				break;
			}

		if (!profile)
			return;

		var name = profile.name || '';
		var mode = profile.mode === 'bypass' ? 'bypass' : 'vpn';
		var modeLabel = (mode === 'bypass') ? _('Bypass mode') : _('VPN mode');
		var close = E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
		]);

		// check_domain answers against the effective profile, so verdicts
		// for any other profile would be misleading — it takes no effect
		// until assigned to the active server.
		if (name !== this._activeProfile) {
			ui.showModal(_('Rule preview'), [
				E('p', {}, _('Profile "%s" is not assigned, so its rules take no effect. Assign it on the Server tab — only the active server\'s profile decides what goes through the tunnel.').format(name)),
				close
			]);
			return;
		}

		var box = E('div', {}, [
			E('p', { 'class': 'spinning' }, _('Checking…'))
		]);

		ui.showModal(_('Rule preview — %s').format(name), [
			E('p', {}, _('How each rule of this profile is treated in %s. The verdicts are computed from the saved settings — press Save & Apply first to preview pending changes.').format(modeLabel)),
			box,
			close
		]);

		// In vpn mode the bypass rules are the exclusions, in bypass mode
		// the VPN rules are the tunneled set; the other list is inert.
		var effective = (mode === 'bypass') ? (profile.vpn_rules || []) : (profile.bypass_rules || []);
		var inert = (mode === 'bypass') ? (profile.bypass_rules || []) : (profile.vpn_rules || []);

		// The checks run one after another, never in parallel.
		var rows = [];
		var chain = Promise.resolve();

		effective.forEach(function(rule) {
			chain = chain.then(function() {
				return callCheckDomain(rule).then(function(res) {
					rows.push(verdictRow(rule, res));
				}).catch(function(e) {
					rows.push(verdictRow(rule, { error: e.message || String(e) }));
				});
			});
		});

		chain.then(function() {
			var nodes = [];

			if (effective.length) {
				nodes.push(E('h4', (mode === 'bypass') ? _('Tunneled by this profile') : _('Bypassed by this profile')));
				nodes.push(E('table', { 'class': 'cbi-section-table' }, [ verdictHead() ].concat(rows)));
			}

			if (inert.length) {
				nodes.push(E('h4', _('No effect in %s').format(modeLabel)));
				nodes.push(E('table', { 'class': 'cbi-section-table' }, [ verdictHead() ].concat(inert.map(function(rule) {
					return E('tr', { 'class': 'cbi-section-table-row' }, [
						E('td', { 'class': 'cbi-section-table-cell' }, E('code', rule)),
						E('td', { 'class': 'cbi-section-table-cell' }, _('no effect')),
						E('td', { 'class': 'cbi-section-table-cell' }, _('this list is ignored in %s').format(modeLabel))
					]);
				}))));
			}

			if (!effective.length && !inert.length)
				nodes.push(E('p', {}, _('This profile has no rules yet.')));

			dom.content(box, nodes);
		}).catch(function(e) {
			dom.content(box, E('p', e.message || String(e)));
		});
	},

	render: function(data) {
		var st = data[2];

		var m = new form.Map('trusttunnel', _('TrustTunnel'));

		m.tabbed = true;

		var s, o;

		// The saved servers and profiles, read through the uci module API
		// (current LuCI resolves uci.load() with the package-name list, so
		// the load() result is no source of config data). The ACTIVE server
		// is the endpoint section whose name matches main.endpoint.
		var servers = uci.sections('trusttunnel', 'endpoint') || [];
		var profiles = uci.sections('trusttunnel', 'routing_profile') || [];
		var activeServerName = uci.get('trusttunnel', 'main', 'endpoint') || '';
		var activeProfileName = '';

		for (var i = 0; i < servers.length; i++)
			if (servers[i].name === activeServerName) {
				activeProfileName = servers[i].routing_profile || '';
				break;
			}

		// Tab 1 — General: the service itself and the server that applies.
		s = m.section(form.NamedSection, 'main', 'main', _('General'));
		s.description = _('When the service runs and which saved server the tunnel uses.');

		o = s.option(form.DummyValue, '_status', _('Service'));
		o.cfgvalue = function() { return statusSummary(st); };

		o = s.option(form.Flag, 'enabled', _('Enable at boot'),
			_('Starts the service when the router boots. The Start button on the Status page launches it immediately.'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Operation mode'),
			_('TUN routes the whole LAN through the client automatically. Proxy runs a SOCKS5 listener instead: point apps and devices that support a proxy at the address on the Proxy tab.'));
		o.value('tun', _('TUN — route the whole LAN'));
		o.value('proxy', _('Proxy — SOCKS5 listener'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'log_level', _('Log level'));
		o.value('info', 'info');
		o.value('debug', 'debug');
		o.value('trace', 'trace');
		o.description = _('debug and trace produce a lot of output; keep them on only while debugging.');

		o = s.option(form.ListValue, 'endpoint', _('Active server'),
			_('The saved server the tunnel uses right now. Servers are added and edited on the Server tab; each server carries its own routing profile.'));

		var currentKnown = false;

		for (var i = 0; i < servers.length; i++) {
			o.value(servers[i].name, servers[i].name);

			if (servers[i].name === activeServerName)
				currentKnown = true;
		}

		// A reference to a deleted server is appended too, so that
		// reference keeps saving (legacy fallback).
		if (activeServerName && !currentKnown)
			o.value(activeServerName, activeServerName);

		// Stash for the per-profile rule preview on the Routing profiles
		// tab: check_domain answers against the ACTIVE server's profile.
		this._profiles = profiles;
		this._activeProfile = activeProfileName;

		// Tab 2 — Server: the saved servers. Every server is one endpoint
		// section, split into Connection/Security inner tabs (map-level
		// tabs key their panes by the UCI section type, so two sections of
		// the same type would collide; section-level tabs are keyed by
		// their own names). The General tab selects the ACTIVE one by the
		// server's name.
		s = m.section(form.TypedSection, 'endpoint', _('Server'));
		s.addremove = true;
		s.anonymous = true;
		s.description = _('The saved servers. The General tab selects the active one; each server carries its own connection settings and routing profile.');

		s.tab('connection', _('Connection'),
			_('How the client reaches this server. The Import server config… button is the quick way.'));
		s.tab('security', _('Security'),
			_('TLS trust and anti-censorship. These rarely need manual changes after importing the server configuration.'));

		// Deleting the ACTIVE server would leave main.endpoint naming a
		// section that no longer exists and the tunnel would stop; the
		// delete is refused while other servers remain. The LAST server
		// may be deleted — the empty state is honest, and the
		// Diagnostics page explains it.
		var realHandleRemove = s.handleRemove;

		s.handleRemove = function(section_id, ev) {
			var removedName = uci.get('trusttunnel', section_id, 'name');

			if (removedName && removedName === uci.get('trusttunnel', 'main', 'endpoint') &&
					(uci.sections('trusttunnel', 'endpoint') || []).length > 1) {
				ui.addNotification(null, E('p', {},
					_('Select another active server on the General tab first — the active server cannot be deleted.')), 'warning');
				return Promise.resolve();
			}

			return realHandleRemove.call(this, section_id, ev);
		};

		o = s.taboption('connection', form.Value, 'name', _('Name'),
			_('Unique name; the General tab selects the active server by it.'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!value)
				return _('Name is required');

			var secs = uci.sections('trusttunnel', 'endpoint') || [];

			for (var i = 0; i < secs.length; i++)
				if (secs[i]['.name'] !== section_id && secs[i].name === value)
					return _('Another server already has this name');

			// Renaming the ACTIVE server moves the selection with it: the
			// General-tab picker parses (and writes) before the endpoint
			// sections, so this later write wins in the same save. When
			// the user switched the selection in the same edit, the
			// section is no longer active here and the selection is left
			// alone.
			if (value !== uci.get('trusttunnel', section_id, 'name') &&
					uci.get('trusttunnel', section_id, 'name') === uci.get('trusttunnel', 'main', 'endpoint'))
				uci.set('trusttunnel', 'main', 'endpoint', value);

			return true;
		};

		o = s.taboption('connection', form.Button, '_import', _('Server configuration'),
			_('The quick way: paste the server output and the fields of THIS server fill in automatically.'));
		o.inputtitle = _('Import server config…');
		o.inputstyle = 'action';
		o.onclick = ui.createHandlerFn(this, 'handleImport');

		o = s.taboption('connection', form.DynamicList, 'address', _('Addresses'),
			_('host:port or [ipv6]:port. With several addresses the client probes them and uses the fastest.'));
		o.placeholder = '203.0.113.10:443';
		o.rmempty = false;

		o = s.taboption('connection', form.Value, 'hostname', _('TLS host name'),
			_('Used for the TLS handshake, not for routing. Many servers refuse the connection without it.'));
		o.datatype = 'hostname';
		o.rmempty = false;

		o = s.taboption('connection', form.Value, 'username', _('User name'));
		o.rmempty = false;

		o = s.taboption('connection', form.Value, 'password', _('Password'));
		o.password = true;
		o.rmempty = false;

		o = s.taboption('connection', form.ListValue, 'protocol', _('Transport'));
		o.value('http2', 'HTTP/2');
		o.value('http3', 'HTTP/3 (QUIC)');
		o.description = _('QUIC is often faster, though some networks throttle or block UDP.');

		o = s.taboption('connection', form.Flag, 'has_ipv6', _('Server carries IPv6'));
		o.default = '1';

		o = s.taboption('connection', form.ListValue, 'routing_profile', _('Routing profile'),
			_('The named profile that decides what goes through the tunnel while THIS server is the active one. Profiles are managed on the Routing profiles tab.'));
		o.value('', _('None — traffic goes out directly'));

		for (var i = 0; i < profiles.length; i++)
			o.value(profiles[i].name, profiles[i].name);

		// Every server's stored assignment is appended too when it
		// references a profile that has been deleted, so that reference
		// keeps saving (legacy fallback).
		var knownProfile = {};

		for (var i = 0; i < profiles.length; i++)
			knownProfile[profiles[i].name] = true;

		for (var i = 0; i < servers.length; i++)
			if (servers[i].routing_profile && !knownProfile[servers[i].routing_profile])
				o.value(servers[i].routing_profile, servers[i].routing_profile);

		o = s.taboption('connection', form.DynamicList, 'dns_upstream', _('DNS the client resolves with'),
			_('Applies to what the TrustTunnel client resolves on its own — for example the exclusion domains it pre-resolves. Empty means the client default, AdGuard DNS unfiltered.'));
		o.placeholder = 'tls://1.1.1.1';
		o.value('tls://1.1.1.1', 'Cloudflare — DNS over TLS');
		o.value('tls://9.9.9.9', 'Quad9 — DNS over TLS');
		o.value('tls://dns.adguard-dns.com', 'AdGuard — DNS over TLS');
		o.value('https://cloudflare-dns.com/dns-query', 'Cloudflare — DNS over HTTPS');
		o.value('https://dns.quad9.net/dns-query', 'Quad9 — DNS over HTTPS');
		o.value('quic://dns.adguard-dns.com', 'AdGuard — DNS over QUIC');
		o.value('1.1.1.1:53', 'Cloudflare — ' + _('plain DNS'));
		o.value('9.9.9.9:53', 'Quad9 — ' + _('plain DNS'));

		o = s.taboption('connection', form.Button, '_test', _('Connection test'),
			_('Loss and round-trip time for every configured address of the ACTIVE server. Uses the saved settings, so press Save & Apply first.'));
		o.inputtitle = _('Test connection');
		o.inputstyle = 'action';
		o.onclick = ui.createHandlerFn(this, 'handleTest');

		o = s.taboption('security', form.Flag, 'anti_dpi', _('Anti-DPI'),
			_('Defences against traffic inspection. Try them when the connection establishes but keeps dropping.'));

		o = s.taboption('security', form.Flag, 'post_quantum', _('Post-quantum key exchange'));
		o.default = '1';

		o = s.taboption('security', form.Value, 'custom_sni', _('Custom SNI'),
			_('Overrides the TLS Server Name. Needed when the server answers on an address that does not match its host name, e.g. behind a CDN or an IP-only setup.'));
		o.placeholder = 'example.com';
		o.optional = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			var v = value.toLowerCase();

			if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/.test(v))
				return _('Use the format example.com');

			return true;
		};

		o = s.taboption('security', form.Value, 'client_random', _('Client Random, hex prefix'),
			_('TLS Client Random prefix and mask. Anti-scan servers accept only clients with the matching prefix. Format: abcdef or abcdef/0f0f0f.'));
		o.placeholder = '0a0b0c/0f0f0f';
		o.optional = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			if (value.length > 64)
				return _('At most 64 characters');

			var parts = value.split('/');

			if (parts.length > 2 || !parts[0] || !/^[0-9a-f]+$/i.test(parts[0]))
				return _('Enter hex digits only, e.g. 0a0b0c or 0a0b0c/0f0f0f');

			if (parts[0].length % 2 !== 0)
				return _('The hex prefix must be a whole number of bytes');

			if (parts.length === 2) {
				if (!/^[0-9a-f]+$/i.test(parts[1]) || parts[1].length % 2 !== 0)
					return _('The mask must be hex digits, a whole number of bytes');

				if (parts[1].length !== parts[0].length)
					return _('The mask must be the same length as the prefix');
			}

			return true;
		};

		o = s.taboption('security', form.Flag, 'skip_verification', _('Skip certificate verification'),
			_('Accepts any certificate, dropping the protection against a substituted server. Prefer pinning the certificate below.'));

		o = s.taboption('security', form.TextValue, 'certificate', _('Pinned certificate (PEM)'),
			_('Leave empty to use the system trust store; that requires the ca-bundle package.'));
		o.rows = 6;
		o.optional = true;

		// Tab 3 — Proxy: the SOCKS5 listener used in proxy mode.
		s = m.section(form.NamedSection, 'proxy', 'proxy', _('Proxy'));
		s.description = _('Used when the operation mode on the General tab is Proxy. The client binds a SOCKS5 listener on this address; every app or device that wants the tunnel must point at it.');

		o = s.option(form.Value, 'address', _('Listen address'),
			_('IP:port to bind. 127.0.0.1:1080 serves the router itself; 0.0.0.0:1080 or the router\'s LAN address serves the whole LAN. The client requires the user name and password for any address outside the loopback.'));
		o.placeholder = '127.0.0.1:1080';
		o.default = '127.0.0.1:1080';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			if (!/^(\[[0-9a-fA-F:]+\]|[0-9a-zA-Z._-]+):[0-9]+$/.test(value))
				return _('Use the format address:port, e.g. 127.0.0.1:1080');

			var port = +value.slice(value.lastIndexOf(':') + 1);

			if (port < 1 || port > 65535)
				return _('Enter a port between 1 and 65535');

			// The client enforces SOCKS authentication for any listener
			// outside the loopback: without credentials the bind fails at
			// start, so the pair below becomes mandatory here.
			var host = value.slice(0, value.lastIndexOf(':'));
			var loopback = host === '127.0.0.1' || host === '::1' ||
				host === '[::1]' || host === 'localhost';

			if (!loopback && !uci.get('trusttunnel', section_id, 'username'))
				return _('Listening outside the loopback requires the user name and password below');

			return true;
		};

		// SOCKS5 authentication is an on/off pair: the client enables it
		// when the user name is set, so a password without a user name (or
		// vice versa) would lock everyone out in a surprising way.
		o = s.option(form.Value, 'username', _('User name'),
			_('Optional SOCKS5 authentication. Leave both fields empty for an open proxy.'));
		o.optional = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			if (!uci.get('trusttunnel', section_id, 'password'))
				return _('Set the password as well — authentication needs both');

			return true;
		};

		o = s.option(form.Value, 'password', _('Password'));
		o.password = true;
		o.optional = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			if (!uci.get('trusttunnel', section_id, 'username'))
				return _('Set the user name as well — authentication needs both');

			return true;
		};

		// Tab 4 — Routing profiles: named rule sets.
		// TypedSection: current LuCI's form module exports no plain
		// `Section` class.
		s = m.section(form.TypedSection, 'routing_profile', _('Routing profiles'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;
		s.description = _('A profile decides what goes through the tunnel. VPN mode tunnels everything except the bypass rules; bypass mode tunnels only the VPN rules. Rules accept a domain, *.domain, an IP address, IP:port, or a CIDR range.');

		// Rules may name a domain, *.domain, an address, address:port or a
		// CIDR block. The client performs the strict validation; this check
		// only rejects values that are obviously wrong.
		function validateRule(value) {
			if (!value)
				return true;

			var v = value.toLowerCase();

			// The special form *:port accepts any destination on that port.
			if (/^\*:[0-9]+$/.test(v))
				return true;

			if (/^\*\./.test(v))
				v = v.slice(2);

			// Plain numeric/hex address forms (with or without a port)
			// are accepted without further checks.
			if (/^[0-9a-f:.\[\]\/]+$/.test(v))
				return true;

			if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/.test(v))
				return _('Not a valid domain, IP or CIDR range');

			return true;
		}

		o = s.option(form.Value, 'name', _('Name'),
			_('Unique name; the General tab assigns a profile by it.'));
		o.optional = false;
		o.validate = function(section_id, value) {
			if (!value)
				return _('Name is required');

			var secs = uci.sections('trusttunnel', 'routing_profile') || [];

			for (var i = 0; i < secs.length; i++)
				if (secs[i]['.name'] !== section_id && secs[i].name === value)
					return _('Another profile already has this name');

			return true;
		};

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.value('vpn', _('VPN — tunnel everything except the bypass rules'));
		o.value('bypass', _('Bypass — tunnel only the VPN rules'));
		o.default = 'vpn';
		o.rmempty = false;

		o = s.option(form.DynamicList, 'vpn_rules', _('VPN rules'),
			_('Sent through the tunnel: in bypass mode these are the only destinations that go through; in VPN mode the list has no effect.'));
		o.placeholder = 'telegram.org';
		o.validate = validateRule;

		o = s.option(form.DynamicList, 'bypass_rules', _('Bypass rules'),
			_('Always sent out directly: in VPN mode these are the only destinations that bypass the tunnel; in bypass mode the list has no effect.'));
		o.placeholder = 'bank.example';
		o.validate = validateRule;

		o = s.option(form.Button, '_preview', _('Rule preview'),
			_('Shows how each rule of this profile is treated, using the same logic as the Check a domain tool. Only the assigned profile takes effect, and the verdicts come from the saved settings.'));
		o.inputtitle = _('Preview rules');
		o.inputstyle = 'action';
		o.onclick = ui.createHandlerFn(this, 'handlePreview');

		// Tab 5 — Advanced: networking internals and the client's own DNS.
		s = m.section(form.NamedSection, 'network', 'network', _('Advanced'));
		s.description = _('These rarely need changing. MTU is the exception: too high a value makes small pages load while TLS handshakes and large downloads stall. The routing options apply in TUN mode only.');

		o = s.option(form.Value, 'mtu', _('MTU'));
		o.datatype = 'range(576,9000)';
		o.default = '1350';

		o = s.option(form.Value, 'lan_devices', _('LAN interfaces'),
			_('Space-separated list of interfaces whose forwarded traffic is routed. Empty uses the lan network device.'));
		o.optional = true;

		// The lan device is read from the network config so the empty-value
		// behaviour is spelled out instead of being a mystery.
		var lanDevice = uci.get('network', 'lan', 'device') || '';

		if (lanDevice) {
			o.description += ' ' + _('Detected: %s').format(lanDevice);
			o.placeholder = lanDevice;
		}
		else {
			o.placeholder = 'br-lan';
		}

		o = s.option(form.Flag, 'blackhole_on_down', _('Drop marked traffic while the tunnel is down'),
			_('Adds a blackhole route so marked traffic is dropped instead of leaking to the ISP.'));
		o.default = '1';

		o = s.option(form.Flag, 'include_router_traffic', _('Also route the router\'s own traffic'),
			_('By default only forwarded LAN traffic is routed. Enabling this also routes traffic originated by the router itself.'));

		o = s.option(form.Value, 'fwmark', _('Firewall mark'),
			_('Decimal or 0x-prefixed hex. Change it only on a conflict with mwan3, SQM or other packet-marking packages.'));
		o.default = '0x9527';
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			if (!/^(0x[0-9a-fA-F]{1,8}|[0-9]{1,10})$/.test(value))
				return _('Enter decimal or 0x-prefixed hex');

			if (!/^0x/i.test(value) && +value > 4294967295)
				return _('Enter a decimal number up to 4294967295');

			return true;
		};

		o = s.option(form.Value, 'table', _('Routing table'),
			_('Any table id except 0 and the reserved range 253-255.'));
		o.datatype = 'uinteger';
		o.default = '880';
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			if (!/^[0-9]+$/.test(value) || +value < 1 || +value > 4294967294)
				return _('Enter a table id from 1 to 4294967294');

			if (+value >= 253 && +value <= 255)
				return _('Table ids 253-255 are reserved by the system');

			return true;
		};

		return m.render();
	}
});
