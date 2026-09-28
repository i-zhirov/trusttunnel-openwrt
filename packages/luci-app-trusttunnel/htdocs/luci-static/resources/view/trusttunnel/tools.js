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

// Fill a result box, spacing it from the button row above. The boxes
// start empty, so the gap appears together with the first content and
// a button that has not been used yet leaves no phantom gap.
var fillBox = function (box, content) {
	dom.content(box, E('div', { 'style': 'margin-top:0.75em' }, content));
};

var handleCheckDomain = function (input, container) {
	var d = input.value.trim();

	if (!d)
		return;

	fillBox(container, E('p', { 'class': 'spinning' }, _('Checking…')));

	callCheckDomain(d).then(function (res) {
		if (res.error) {
			fillBox(container, E('p', res.error));
			return;
		}

		var tunnel = res.verdict && res.verdict.indexOf('tunnel') === 0;

		fillBox(container, E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td nowrap' }, _('Normalized')),
				E('td', { 'class': 'td', 'style': 'width:100%' }, E('code', res.normalized))
			]),
			E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td nowrap' }, _('Verdict')),
				E('td', { 'class': 'td', 'style': 'width:100%' },
					E('span', { 'style': 'font-weight:bold; color:' + (tunnel ? '#2e7d32' : '#c62828') + ';' },
						tunnel ? _('through the tunnel') : _('direct')
					)
				)
			]),
			E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td nowrap' }, _('Why')),
				E('td', { 'class': 'td', 'style': 'width:100%' }, res.reason)
			])
		]));
	}).catch(function (err) {
		fillBox(container, E('p', err.message || String(err)));
	});
};

var handlePing = function (container) {
	fillBox(container, E('p', { 'class': 'spinning' }, _('Pinging…')));

	callPing('').then(function (res) {
		if (res.error) {
			fillBox(container, E('p', res.error));
			return;
		}

		var rows = [ E('tr', { 'class': 'tr cbi-section-table-row' }, [
			E('th', { 'class': 'th cbi-section-table-cell' }, _('Host')),
			E('th', { 'class': 'th cbi-section-table-cell' }, _('Loss')),
			E('th', { 'class': 'th cbi-section-table-cell', 'style': 'width:100%' }, _('min / avg / max'))
		]) ];

		(res.results || []).forEach(function (r) {
			rows.push(E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td' }, r.host),
				E('td', { 'class': 'td' }, r.loss + '%'),
				E('td', { 'class': 'td', 'style': 'width:100%' },
					r.avg === null ? '—' : r.min + ' / ' + r.avg + ' / ' + r.max + ' ms'
				)
			]));
		});

		fillBox(container, E('table', { 'class': 'table cbi-section-table' }, rows));
	}).catch(function (err) {
		fillBox(container, E('p', err.message || String(err)));
	});
};

var handleProbe = function (container) {
	fillBox(container, E('p', { 'class': 'spinning' }, _('Checking…')));

	callProbe().then(function (res) {
		var cell = function (entry) {
			if (entry && entry.ip)
				return E('code', entry.ip);

			return E('span', { 'style': 'color:#c62828;' },
				(entry && entry.error) ? entry.error : '');
		};

		fillBox(container, E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td nowrap' }, _('Through the tunnel')),
				E('td', { 'class': 'td', 'style': 'width:100%' }, cell(res.tunnel))
			]),
			E('tr', { 'class': 'tr cbi-section-table-row' }, [
				E('td', { 'class': 'td nowrap' }, _('Directly')),
				E('td', { 'class': 'td', 'style': 'width:100%' }, cell(res.direct))
			])
		]));
	}).catch(function (err) {
		fillBox(container, E('p', err.message || String(err)));
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
