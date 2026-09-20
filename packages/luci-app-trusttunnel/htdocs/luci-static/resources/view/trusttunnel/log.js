'use strict';

'require view';
'require poll';
'require rpc';
'require ui';

var callLog = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'log',
	params: [ 'lines' ],
	expect: {}
});

// The on-screen tail is 80 lines; the export fetches the whole ring
// buffer the system log keeps for the client and the service.
var EXPORT_LINES = 5000;

// A file name for the export: trusttunnel-client-20260919-105400.log.
var exportFileName = function() {
	var d = new Date();
	var p = function(n) { return (n < 10 ? '0' : '') + n; };

	return 'trusttunnel-client-' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) +
		'-' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds()) + '.log';
};

// Download the exported tail as a text file. The browser keeps the
// download attribute of the generated anchor, so no server round-trip
// and no extra backend surface are needed.
var exportLog = function() {
	return callLog(EXPORT_LINES).then(function(res) {
		var text = (res.lines || []).join('\n') + '\n';
		var url = URL.createObjectURL(new Blob([ text ], { type: 'text/plain' }));
		var a = E('a', { 'href': url, 'download': exportFileName() });

		document.body.appendChild(a);
		a.click();
		document.body.removeChild(a);
		// Defer the revoke: Firefox can abort a download whose blob URL
		// is revoked before the browser has picked it up.
		setTimeout(function() { URL.revokeObjectURL(url); }, 0);
	}).catch(function(e) {
		ui.addNotification(null, E('p', e.message || String(e)), 'danger');
	});
};

return view.extend({
	// Nothing to save on this page: without the nulls LuCI renders the
	// default Save & Apply bar, which would sit here dead.
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	// Fetch the tail once during load so the first paint already shows
	// the log; the poll keeps it fresh afterwards.
	load: function() {
		return callLog(80);
	},

	render: function(entry) {
		// The poll refreshes the text in place — no spinner flash on
		// every 10 s tick. A failed poll leaves the last content
		// untouched; the next tick retries.
		var logBox = E('pre', { 'style': 'max-height:24em;overflow:auto;margin:0' });
		logBox.textContent = (entry.lines || []).join('\n');

		poll.add(function() {
			return callLog(80).then(function(next) {
				logBox.textContent = (next.lines || []).join('\n');
			}).catch(function() {});
		}, 10);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('TrustTunnel')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Client log')),
				E('p', { 'class': 'cbi-section-descr' }, _('The last lines the client and the service wrote to the system log, refreshed every ten seconds.')),
				logBox,
				E('div', { 'style': 'margin-top:0.75em' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function(ev) { exportLog(); }
					}, _('Export client logs'))
				])
			])
		]);
	}
});
