'use strict';

'require view';
'require rpc';
'require dom';
'require ui';

var callDiagnose = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'diagnose'
});

var alertClass = {
	ok: 'success',
	warn: 'warning',
	fail: 'danger',
	skip: 'info'
};

var verdictWord = function (verdict) {
	switch (verdict) {
	case 'ok':
		return _('everything checks out');

	case 'warn':
		return _('works, with remarks');

	case 'fail':
		return _('there are problems');
	}

	return _('not run yet');
};

var checkMark = {
	ok: { word: _('ok'), color: '#2e7d32' },
	warn: { word: _('check'), color: '#ef6c00' },
	fail: { word: _('problem'), color: '#c62828' },
	skip: { word: _('skipped'), color: '#757575' }
};

var groupTitle = {
	config: _('Configuration'),
	prereq: _('Prerequisites'),
	service: _('Service state'),
	kernel: _('Kernel state'),
	network: _('Connectivity')
};

var DIAG_TEXT = {
	'Server address': _('Server address'),
	'Endpoint credentials': _('Endpoint credentials'),
	'TLS SNI': _('TLS SNI'),
	'Routing profile': _('Routing profile'),
	'Client binary': _('Client binary'),
	'TUN device': _('TUN device'),
	'Service enabled': _('Service enabled'),
	'Service running': _('Service running'),
	'Tunnel device': _('Tunnel device'),
	'Route attached to the device': _('Route attached to the device'),
	'Carrier state': _('Carrier state'),
	'MTU matches config': _('MTU matches config'),
	'SOCKS listener': _('SOCKS listener'),
	'none — legacy full-tunnel mode': _('none — legacy full-tunnel mode'),
	'request error': _('request error'),
	'Marking rule': _('Marking rule'),
	'Routing-table entry': _('Routing-table entry'),
	'nft ruleset': _('nft ruleset'),
	'Zone binding': _('Zone binding'),
	'Server reachable': _('Server reachable'),
	'Traffic takes the tunnel': _('Traffic takes the tunnel'),
	'Set the address on the Settings page or import the server config.': _('Set the address on the Settings page or import the server config.'),
	'The user name and the password must both be filled in.': _('The user name and the password must both be filled in.'),
	'Without it the TLS session uses the plain address, which many servers reject.': _('Without it the TLS session uses the plain address, which many servers reject.'),
	'Assign a routing profile on the Settings page to control what goes through the tunnel.': _('Assign a routing profile on the Settings page to control what goes through the tunnel.'),
	'The client is a dependency of the package; reinstall trusttunnel-client.': _('The client is a dependency of the package; reinstall trusttunnel-client.'),
	'Install the kmod-tun package.': _('Install the kmod-tun package.'),
	'Enable the service on the Settings page, then press Start.': _('Enable the service on the Settings page, then press Start.'),
	'Press Start and open the Client log tab.': _('Press Start and open the Client log tab.'),
	'Set the listener address on the Settings page.': _('Set the listener address on the Settings page.'),
	'The listener is bound by the client at start; a bind error or a port conflict keeps it down. Open the Client log tab.': _('The listener is bound by the client at start; a bind error or a port conflict keeps it down. Open the Client log tab.'),
	'The tun device is created by the client, not by this package. Open the Client log tab.': _('The tun device is created by the client, not by this package. Open the Client log tab.'),
	'Restart the service so the client applies the configured value.': _('Restart the service so the client applies the configured value.'),
	'Marked traffic hits the blackhole route instead of the tunnel. Restart the service.': _('Marked traffic hits the blackhole route instead of the tunnel. Restart the service.'),
	'Run /etc/init.d/firewall reload — without the zone, traffic into the tunnel is dropped.': _('Run /etc/init.d/firewall reload — without the zone, traffic into the tunnel is dropped.'),
	'The device exists but the tunnel is not established yet; that is on the client, not the routing. Open the Client log tab.': _('The device exists but the tunnel is not established yet; that is on the client, not the routing. Open the Client log tab.'),
	'Check the address and whether the router itself can reach the internet.': _('Check the address and whether the router itself can reach the internet.'),
	'The tunnel is up, yet traffic is not going through it.': _('The tunnel is up, yet traffic is not going through it.'),
	'The probe that should take the tunnel egressed directly — the client may send it out directly (a stale config or an exclusion match), the marking rules may still carry the output chain from an include_router_traffic=1 configuration, or the router shares its public address with the endpoint. Reload the service, or judge by a LAN client.': _('The probe that should take the tunnel egressed directly — the client may send it out directly (a stale config or an exclusion match), the marking rules may still carry the output chain from an include_router_traffic=1 configuration, or the router shares its public address with the endpoint. Reload the service, or judge by a LAN client.'),
	'nothing is tunneled by config': _('nothing is tunneled by config'),
	'The assigned profile runs in bypass mode and its VPN rules are empty: the client sends every connection out directly. Add rules to the profile, or switch it to VPN mode.': _('The assigned profile runs in bypass mode and its VPN rules are empty: the client sends every connection out directly. Add rules to the profile, or switch it to VPN mode.'),
	'the tunneled rules cannot be probed': _('the tunneled rules cannot be probed'),
	'The profile tunnels only IP or CIDR rules, which a plain HTTPS request cannot reach through the tunnel.': _('The profile tunnels only IP or CIDR rules, which a plain HTTPS request cannot reach through the tunnel.'),
	'the echo services are bypassed by config': _('the echo services are bypassed by config'),
	'The profile sends the probe services (api.ipify.org, ifconfig.me, icanhazip.com) out directly; the tunnel path cannot be compared from the router.': _('The profile sends the probe services (api.ipify.org, ifconfig.me, icanhazip.com) out directly; the tunnel path cannot be compared from the router.'),
	'A request through the SOCKS listener can fail on a healthy tunnel while the client is still connecting. Judge by a LAN client instead.': _('A request through the SOCKS listener can fail on a healthy tunnel while the client is still connecting. Judge by a LAN client instead.'),
	'A request bound to the device can fail on a healthy tunnel because the default route lives in the marked table. Judge by a LAN client instead.': _('A request bound to the device can fail on a healthy tunnel because the default route lives in the marked table. Judge by a LAN client instead.'),
	'unset': _('unset'),
	'binary missing': _('binary missing'),
	'not present': _('not present'),
	'not bound': _('not bound'),
	'address unset': _('address unset'),
	'the service is stopped': _('the service is stopped'),
	'on': _('on'),
	'off': _('off'),
	'found': _('found'),
	'not found': _('not found'),
	'link up': _('link up'),
	'link down': _('link down'),
	'the client has not created it yet': _('the client has not created it yet'),
	'not attached': _('not attached'),
	'in the fw4 ruleset': _('in the fw4 ruleset'),
	'missing from the fw4 ruleset': _('missing from the fw4 ruleset'),
	'/dev/net/tun present': _('present')
};

var dtr = function (s) {
	if (!s)
		return '';

	return DIAG_TEXT[s] || s;
};

var markCell = function (status) {
	var m = checkMark[status] || { word: status, color: '#757575' };

	return E('td', {
		'class': 'cbi-section-table-cell',
		'style': 'width:6.5em; font-weight:bold; color:' + m.color + ';'
	}, m.word);
};

var renderChecks = function (checks) {
	var nodes = [];
	var order = [ 'config', 'prereq', 'service', 'kernel', 'network' ];

	order.forEach(function (group) {
		var rows = [];
		var present = false;

		checks.forEach(function (check) {
			if (check.group !== group)
				return;

			present = true;
			// Children as an ARRAY: current LuCI's E() (DOM.create) reads
			// only arguments[2], so variadic children are silently dropped.
			rows.push(E('tr', { 'class': 'cbi-section-table-row' }, [
				markCell(check.status),
				E('td', { 'class': 'cbi-section-table-cell' }, dtr(check.label)),
				E('td', { 'class': 'cbi-section-table-cell' }, dtr(check.detail))
			]));

			if (check.hint)
				rows.push(E('tr', { 'class': 'cbi-section-table-row' },
					E('td', { 'class': 'cbi-section-table-cell', 'colspan': '3' },
						E('em', dtr(check.hint))
					)
				));
		});

		if (present) {
			nodes.push(E('h4', groupTitle[group] || group));
			nodes.push(E('table', { 'class': 'cbi-section-table' }, rows));
		}
	});

	return nodes;
};

var verdictBanner = function (res) {
	var counts = res.counts || {};

	return E('div', { 'class': 'alert-message ' + (alertClass[res.verdict] || 'info') }, [
		E('strong', verdictWord(res.verdict)),
		E('br'),
		_('checks passed: %d, remarks: %d, problems: %d, skipped: %d').format(counts.ok || 0, counts.warn || 0, counts.fail || 0, counts.skip || 0)
	]);
};

// The last diagnose result, kept so the report button can serialize it
// without re-running the (slow) chain walk.
var lastDiagnose = null;

// Plain-text rendering of a diagnose result for pasting into a bug
// report. Uses the translated labels, so the report reads like the page.
var serializeDiagnose = function (res) {
	var counts = res.counts || {};
	var lines = [
		_('Verdict: %s').format(verdictWord(res.verdict)),
		_('checks passed: %d, remarks: %d, problems: %d, skipped: %d').format(counts.ok || 0, counts.warn || 0, counts.fail || 0, counts.skip || 0)
	];
	var order = [ 'config', 'prereq', 'service', 'kernel', 'network' ];

	order.forEach(function (group) {
		var groupLines = [];

		(res.checks || []).forEach(function (check) {
			if (check.group !== group)
				return;

			groupLines.push('[' + check.status + '] ' + dtr(check.label) +
				(check.detail ? ' — ' + dtr(check.detail) : '') +
				(check.hint ? ' — ' + dtr(check.hint) : ''));
		});

		if (groupLines.length) {
			lines.push('');
			lines.push(groupTitle[group] || group);
			lines = lines.concat(groupLines);
		}
	});

	return lines.join('\n');
};

var renderDiagnose = function (res) {
	var problems = [];
	var rest = [];
	var nodes = [ verdictBanner(res) ];

	(res.checks || []).forEach(function (check) {
		if (check.status === 'fail' || check.status === 'warn')
			problems.push(check);
		else
			rest.push(check);
	});

	nodes = nodes.concat(renderChecks(problems));

	if (rest.length) {
		var box = E('div', { 'style': 'display:none;' }, renderChecks(rest));
		var label = problems.length ? _('Show the checks that passed') : _('Show all checks');
		var toggle = E('button', {
			'class': 'cbi-button',
			click: function () {
				var hidden = box.style.display === 'none';

				box.style.display = hidden ? '' : 'none';
				toggle.firstChild.nodeValue = hidden ? _('Hide') : label;
			}
		}, label);

		nodes.push(toggle);
		nodes.push(box);
	}

	return nodes;
};

var handleDiagnose = function (container) {
	dom.content(container, E('p', { 'class': 'spinning' }, _('Running checks — this can take up to half a minute…')));

	callDiagnose().then(function (res) {
		lastDiagnose = res;
		dom.content(container, renderDiagnose(res));
	}).catch(function (err) {
		dom.content(container, E('div', { 'class': 'alert-message danger' }, err.message || String(err)));
	});
};

var handleCopyReport = function () {
	if (!lastDiagnose)
		return;

	var ta = E('textarea', {
		'readonly': 'readonly',
		'rows': 16,
		'style': 'width:100%',
		'value': serializeDiagnose(lastDiagnose)
	});

	ui.showModal(_('Diagnostics report'), [
		E('p', {}, _('Copy this text and attach it when reporting a problem.')),
		ta,
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
		])
	]);
};

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	render: function () {
		var diagnoseBox = E('div');

		// The chain walk is slow (it pings and probes) and touches the
		// network; it runs only when the user presses Run checks. The
		// 'not run yet' word comes from verdictWord(), the same phrasing
		// the banner would use for a run that produced no verdict; the
		// info banner keeps the empty state looking like the verdict
		// banner instead of stray text.
		dom.content(diagnoseBox, E('div', { 'class': 'alert-message info' }, verdictWord('')));

		// Children as an ARRAY: current LuCI's E() (DOM.create) reads only
		// arguments[2], so variadic children are silently dropped — this
		// used to render nothing but the page title.
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('Diagnostics')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Checks')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Checks the whole chain — configuration, prerequisites, service, kernel state and network — and says what to do about anything it finds.')
				),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, function () {
						handleDiagnose(diagnoseBox);
					})
				}, _('Run checks')),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': ui.createHandlerFn(this, function () {
						handleCopyReport();
					})
				}, _('Copy report')),
				diagnoseBox
			])
		]);
	}
});
