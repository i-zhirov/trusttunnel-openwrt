'use strict';

// The ad-hoc tools that used to live on the Diagnostics page: check a
// domain against the effective rules, ping the endpoint, and compare the
// external address through the tunnel with the direct one. Each runs only
// on demand — the page itself does no RPC.

'require view';
'require rpc';
'require dom';
'require ui';

var callPing = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'ping',
	params: [ 'target' ]
});

var callProbe = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'probe'
});

var callCheckDomain = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'check_domain',
	params: [ 'domain' ]
});

var handleCheckDomain = function (input, container) {
	var d = input.value.trim();

	if (!d)
		return;

	dom.content(container, E('p', { 'class': 'spinning' }, _('Checking…')));

	callCheckDomain(d).then(function (res) {
		if (res.error) {
			dom.content(container, E('p', res.error));
			return;
		}

		var tunnel = res.verdict && res.verdict.indexOf('tunnel') === 0;

		dom.content(container, E('table', { 'class': 'cbi-section-table' }, [
			E('tr', { 'class': 'cbi-section-table-row' }, [
				E('td', { 'class': 'cbi-section-table-cell' }, _('Normalized')),
				E('td', { 'class': 'cbi-section-table-cell' }, E('code', res.normalized))
			]),
			E('tr', { 'class': 'cbi-section-table-row' }, [
				E('td', { 'class': 'cbi-section-table-cell' }, _('Verdict')),
				E('td', { 'class': 'cbi-section-table-cell' },
					E('span', { 'style': 'font-weight:bold; color:' + (tunnel ? '#2e7d32' : '#c62828') + ';' },
						tunnel ? _('through the tunnel') : _('direct')
					)
				)
			]),
			E('tr', { 'class': 'cbi-section-table-row' }, [
				E('td', { 'class': 'cbi-section-table-cell' }, _('Why')),
				E('td', { 'class': 'cbi-section-table-cell' }, res.reason)
			])
		]));
	}).catch(function (err) {
		dom.content(container, E('p', err.message || String(err)));
	});
};

var handlePing = function (container) {
	dom.content(container, E('p', { 'class': 'spinning' }, _('Pinging…')));

	callPing('').then(function (res) {
		if (res.error) {
			dom.content(container, E('p', res.error));
			return;
		}

		var rows = [ E('tr', { 'class': 'cbi-section-table-row' }, [
			E('th', { 'class': 'cbi-section-table-cell' }, _('Host')),
			E('th', { 'class': 'cbi-section-table-cell' }, _('Loss')),
			E('th', { 'class': 'cbi-section-table-cell' }, _('min / avg / max'))
		]) ];

		(res.results || []).forEach(function (r) {
			rows.push(E('tr', { 'class': 'cbi-section-table-row' }, [
				E('td', { 'class': 'cbi-section-table-cell' }, r.host),
				E('td', { 'class': 'cbi-section-table-cell' }, r.loss + '%'),
				E('td', { 'class': 'cbi-section-table-cell' },
					r.avg === null ? '—' : r.min + ' / ' + r.avg + ' / ' + r.max + ' ms'
				)
			]));
		});

		dom.content(container, E('table', { 'class': 'cbi-section-table' }, rows));
	}).catch(function (err) {
		dom.content(container, E('p', err.message || String(err)));
	});
};

var handleProbe = function (container) {
	dom.content(container, E('p', { 'class': 'spinning' }, _('Checking…')));

	callProbe().then(function (res) {
		var cell = function (entry) {
			if (entry && entry.ip)
				return E('code', entry.ip);

			return E('span', { 'style': 'color:#c62828;' },
				(entry && entry.error) ? entry.error : '');
		};

		dom.content(container, E('table', { 'class': 'cbi-section-table' }, [
			E('tr', { 'class': 'cbi-section-table-row' }, [
				E('td', { 'class': 'cbi-section-table-cell' }, _('Through the tunnel')),
				E('td', { 'class': 'cbi-section-table-cell' }, cell(res.tunnel))
			]),
			E('tr', { 'class': 'cbi-section-table-row' }, [
				E('td', { 'class': 'cbi-section-table-cell' }, _('Directly')),
				E('td', { 'class': 'cbi-section-table-cell' }, cell(res.direct))
			])
		]));
	}).catch(function (err) {
		dom.content(container, E('p', err.message || String(err)));
	});
};

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	render: function () {
		var domainBox = E('div');
		var pingBox = E('div');
		var probeBox = E('div');

		var domainInput = E('input', {
			'class': 'cbi-input-text',
			'placeholder': 'youtube.com',
			'style': 'width:16em;'
		});

		domainInput.addEventListener('keydown', function (ev) {
			if (ev.keyCode !== 13)
				return;

			ev.preventDefault();
			handleCheckDomain(domainInput, domainBox);
		});

		// Children as an ARRAY: current LuCI's E() (DOM.create) reads only
		// arguments[2], so variadic children are silently dropped — this
		// used to render nothing but the page title.
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('Tools')),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Check a domain')),
				E('div', { 'class': 'cbi-section-descr' },
					_('The tool to reach for when a particular site does not work: it says whether that domain goes through the tunnel, and why.')
				),
				domainInput,
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, function () {
						handleCheckDomain(domainInput, domainBox);
					})
				}, _('Run checks')),
				domainBox
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Ping the server')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Loss and round-trip time for every configured address.')
				),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, function () {
						handlePing(pingBox);
					})
				}, _('Ping server')),
				pingBox
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Compare the external address')),
				E('div', { 'class': 'cbi-section-descr' },
					_('Shows the address seen through the tunnel next to the one seen directly. The same address in both means traffic is not using the tunnel.')
				),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, function () {
						handleProbe(probeBox);
					})
				}, _('Compare addresses')),
				probeBox
			])
		]);
	}
});
