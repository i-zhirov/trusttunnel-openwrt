'use strict';

'require view';
'require poll';
'require rpc';

var callLog = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'log',
	params: [ 'lines' ],
	expect: {}
});

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
				logBox
			])
		]);
	}
});
