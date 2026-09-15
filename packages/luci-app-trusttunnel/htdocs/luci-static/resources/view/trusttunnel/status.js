'use strict';

'require view';
'require poll';
'require rpc';
'require ui';
'require dom';
'require uci';

var callStatus = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'status',
	params: [],
	expect: {}
});

var callService = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'service',
	params: [ 'action' ],
	expect: {}
});

var callLog = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'log',
	params: [ 'lines' ],
	expect: {}
});

var callCheckDomain = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'check_domain',
	params: [ 'domain' ],
	expect: {}
});

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
	verdict: function(st) {
		var host = st.endpoint_hostname || (st.addresses || [])[0] || '';

		if (!st.client_installed)
			return {
				level: 'danger',
				head: _('The TrustTunnel client is not installed'),
				detail: _('Run install.sh: the package does not ship the client binary.')
			};

		if (!st.running) {
			if (st.enabled)
				return {
					level: 'danger',
					head: _('The service is not running'),
					detail: _('Press Start and read the client log below.')
				};

			return {
				level: 'info',
				head: _('The service is off'),
				detail: _('Press Start to run it now, or turn on "Start on boot" in Settings.')
			};
		}

		// Proxy mode has no tun device: the SOCKS listener state is the
		// liveness signal, and the device_up gate below is tun-only.
		if (st.mode === 'proxy' && !st.listener_up)
			return {
				level: 'warning',
				head: host ? _('Connecting to %s').format(host) : _('Connecting to the server'),
				detail: _('The client is running but the SOCKS listener is not up yet. If this persists, the client log below says why.')
			};

		if (st.mode !== 'proxy' && !st.device_up)
			return {
				level: 'warning',
				head: host ? _('Connecting to %s').format(host) : _('Connecting to the server'),
				detail: _('The client is running but the tunnel is not established yet. If this persists, the client log below says why.')
			};

		if (st.routing_profile && st.routing_mode === 'bypass')
			return {
				level: 'success',
				head: host ? _('Tunnel works, profile %s — only the VPN rules go through %s').format(st.routing_profile, host)
				           : _('Tunnel works, profile %s — only the VPN rules go through the tunnel').format(st.routing_profile),
				detail: _('Everything else stays direct.')
			};

		// An unknown profile mode is treated like the legacy full-tunnel
		// mode: gen-config falls back to domains.direct + general for
		// anything other than bypass/vpn, so describing the profile as
		// VPN would mislead.
		if (st.routing_profile && st.routing_mode === 'vpn')
			return {
				level: 'success',
				head: host ? _('Tunnel works, profile %s — everything except the bypass rules goes through %s').format(st.routing_profile, host)
				           : _('Tunnel works, profile %s — everything except the bypass rules goes through the tunnel').format(st.routing_profile),
				detail: _('The bypass rules are sent out directly.')
			};

		if (st.mode === 'proxy')
			return {
				level: 'success',
				head: host ? _('Proxy traffic goes through %s').format(host) : _('Proxy traffic goes through the tunnel'),
				detail: _('Domains from the "do not bypass" list are sent out directly.')
			};

		return {
			level: 'success',
			head: host ? _('All LAN traffic goes through %s').format(host) : _('All LAN traffic goes through the tunnel'),
			detail: _('Domains from the "do not bypass" list are sent out directly.')
		};
	},

	renderBanner: function(st) {
		var v = this.verdict(st);

		if (v.level === 'success')
			return E('div');

		// Children as an ARRAY: dom.create() reads only arguments[2], so
		// the detail line was silently dropped. Nulls must not be passed
		// in the array either — dom.append() turns them into "null" text.
		var nodes = [ E('strong', v.head) ];

		if (v.detail)
			nodes.push(E('br'), v.detail);

		return E('div', { 'class': 'alert-message ' + v.level }, nodes);
	},

	row: function(label, value) {
		// The value cell wraps its content in an array: current LuCI's
		// E() (DOM.create) treats an element in the SECOND argument
		// position as attributes, not data — a bare element value (the
		// State span, the Server code) used to render an empty cell.
		return E('tr', [
			E('td', { 'class': 'left', 'style': 'width:30%' }, label),
			E('td', [value])
		]);
	},

	renderFactRows: function(st) {
		var rows = [];

		if (this.verdict(st).level === 'success')
			rows.push(this.row(_('State'), E('span', { 'style': 'color:#57bc48;font-weight:bold' }, _('working'))));

		if (st.routing_profile) {
			if (st.routing_mode === 'bypass')
				rows.push(this.row(_('Mode'), _('Profile %s — bypass, only the VPN rules are tunneled').format(st.routing_profile)));
			else if (st.routing_mode === 'vpn')
				rows.push(this.row(_('Mode'), _('Profile %s — VPN, everything except the bypass rules is tunneled').format(st.routing_profile)));
			else
				rows.push(this.row(_('Mode'), _('Everything through VPN')));
		}
		else {
			rows.push(this.row(_('Mode'), _('Everything through VPN')));
		}

		if (st.endpoint_hostname)
			rows.push(this.row(_('Server'), E('code', st.endpoint_hostname)));

		if (st.mode === 'proxy' && st.proxy_address)
			rows.push(this.row(_('Proxy'), E('code', st.proxy_address)));

		return E('table', { 'class': 'table' }, rows);
	},

	runAction: function(action, ev) {
		ui.showModal(_('Please wait'), E('p', { 'class': 'spinning' }, _('Running…')));

		callService(action).then(function(res) {
			ui.hideModal();

			if (res.not_running)
				ui.addNotification(null, E('p', _('The service did not start. The client log below says why.')), 'warning');
			else if (res.code !== 0)
				ui.addNotification(null, E('pre', res.output || _('Command failed')), 'warning');
			else
				ui.addNotification(null, E('p', _('Done')), 'info');
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', e.message || String(e)), 'danger');
		});
	},

	handlePreview: function(st) {
		var me = this;
		var name = (st && st.routing_profile) || '';

		// The mode comes from the status: the records it reflects are the
		// same ones check_domain answers from, so an edited-but-not-applied
		// profile previews exactly like the verdicts compute it.
		var mode = (name && st.routing_mode === 'bypass') ? 'bypass'
		         : (name && st.routing_mode === 'vpn') ? 'vpn' : '';
		var modeLabel = mode === 'bypass' ? _('Bypass mode') : _('VPN mode');

		var box = E('div', {}, [
			E('p', { 'class': 'spinning' }, _('Checking…'))
		]);

		var close = E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
		]);

		ui.showModal(mode ? _('Rule preview — %s').format(name) : _('Rule preview'), [
			mode
				? E('p', {}, _('How each rule of this profile is treated in %s. The verdicts come from the applied settings — press Save & Apply on the Settings page to preview pending changes.').format(modeLabel))
				: E('p', {}, _('No routing profile is assigned, so everything goes through the tunnel except the "do not bypass" list below.')),
			box,
			close
		]);

		uci.load('trusttunnel').then(function() {
			var profile = null;
			var secs = uci.sections('trusttunnel', 'routing_profile') || [];

			for (var i = 0; i < secs.length; i++)
				if (secs[i].name === name) {
					profile = secs[i];
					break;
				}

			// In vpn mode the bypass rules are the exclusions, in bypass
			// mode the VPN rules are the tunneled set; the other list is
			// inert. Without a profile (or with an unrecognized one) the
			// backend falls back to the legacy domains.direct list, so
			// the preview does too.
			var effective = [], inert = [];

			if (mode && profile) {
				if (mode === 'bypass') {
					effective = profile.vpn_rules || [];
					inert = profile.bypass_rules || [];
				}
				else {
					effective = profile.bypass_rules || [];
					inert = profile.vpn_rules || [];
				}
			}
			else {
				effective = uci.get('trusttunnel', 'domains', 'direct') || [];
			}

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
					nodes.push(E('h4', mode
						? (mode === 'bypass' ? _('Tunneled by this profile') : _('Bypassed by this profile'))
						: _('The "do not bypass" list')));
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
					nodes.push(E('p', {}, mode
						? _('This profile has no rules yet.')
						: _('The "do not bypass" list is empty — everything goes through the tunnel.')));

				dom.content(box, nodes);
			}).catch(function(e) {
				dom.content(box, E('p', e.message || String(e)));
			});
		}).catch(function(e) {
			dom.content(box, E('p', e.message || String(e)));
		});
	},

	load: function() {
		return callStatus();
	},

	render: function(st) {
		var me = this;

		// The Preview rules button answers for the newest status the polls
		// have seen, not the load-time snapshot.
		me._lastStatus = st;

		var bannerBox = E('div', {}, this.renderBanner(st));
		var factRows = E('div', {}, this.renderFactRows(st));

		// The first log fetch only runs on the first poll tick and
		// logread over RPC takes a while, so show a spinner in the log
		// section until the first response lands. Later polls only
		// refresh the text — no spinner flash on every 10 s tick.
		var logBox = E('pre', { 'style': 'max-height:22em;overflow:auto;margin:0' });
		var logArea = E('div', {}, E('p', { 'class': 'spinning' }, _('Loading…')));
		var logReady = false;

		// The status and the client log are polled on the same cadence;
		// the first log response swaps the spinner for the real box.
		var refreshStatus = function() {
			return callStatus().then(function(snap) {
				me._lastStatus = snap;
				dom.content(bannerBox, me.renderBanner(snap));
				dom.content(factRows, me.renderFactRows(snap));
			});
		};
		var refreshLog = function() {
			return callLog(80).then(function(entry) {
				logBox.textContent = (entry.lines || []).join('\n');

				if (!logReady) {
					logReady = true;
					dom.content(logArea, logBox);
				}
			}).catch(function() {
				// A failed first fetch must not leave the spinner
				// spinning forever: swap in the empty box, the next
				// poll retries.
				if (!logReady) {
					logReady = true;
					dom.content(logArea, logBox);
				}
			});
		};

		poll.add(refreshStatus, 10);
		poll.add(refreshLog, 10);

		// The three service actions are declared as data and turned into
		// buttons here, so the row stays a single place to extend.
		var controls = [
			{ verb: 'start', tone: 'apply', word: _('Enable') },
			{ verb: 'stop', tone: 'reset', word: _('Disable') },
			{ verb: 'restart', tone: 'action', word: _('Restart service') }
		];
		var controlRow = [];

		controls.forEach(function(c, i) {
			if (i)
				controlRow.push(' ');

			controlRow.push(E('button', {
				'class': 'cbi-button cbi-button-' + c.tone,
				'click': function(ev) { me.runAction(c.verb, ev); }
			}, c.word));
		});

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('TrustTunnel')),
			E('div', { 'class': 'cbi-section' }, [
				bannerBox,
				E('div', controlRow)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Now')),
				factRows,
				E('div', { 'style': 'margin-top:0.75em' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function(ev) { me.handlePreview(me._lastStatus); }
					}, _('Preview rules'))
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Client log')),
				logArea
			])
		]);
	}
});
