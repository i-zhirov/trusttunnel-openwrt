'use strict';

// The Versions tab (moved out of the Settings page): what is installed,
// read-only. The values come from the backend's versions RPC, not from
// UCI; updates are delivered through the package manager, not here.

'require view';
'require rpc';

var callVersions = rpc.declare({
	object: 'luci.trusttunnel',
	method: 'versions'
});

// versionCell(value) — the display value for one row: the backend reports
// null for a package that is not installed, and the RPC failure path (a
// rejected promise from load) renders 'unavailable' for the whole page.
function versionCell(v) {
	if (!v)
		return _('not installed');

	return E('code', v);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		// A versions failure must not take the page down: null renders
		// 'unavailable' on every row.
		return callVersions().catch(function() { return null; });
	},

	render: function(versions) {
		var row = function(label, value) {
			return E('tr', { 'class': 'cbi-section-table-row' }, [
				E('td', { 'class': 'cbi-section-table-cell' }, label),
				E('td', { 'class': 'cbi-section-table-cell' }, value)
			]);
		};

		// Children as an ARRAY: current LuCI's E() (DOM.create) reads only
		// arguments[2], so variadic children are silently dropped.
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('Versions')),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-section-descr' },
					_('The installed TrustTunnel packages and the client binary. Updates are delivered through the package manager, not this page: apk update && apk upgrade on OpenWrt 25.12, opkg update && opkg upgrade before it.')
				),
				E('table', { 'class': 'cbi-section-table' }, [
					row(_('TrustTunnel package'), versionCell(versions ? versions.package : null)),
					row(_('Client package'), versionCell(versions ? versions.client_package : null)),
					row(_('Client binary'), versionCell(versions ? versions.client : null))
				])
			])
		]);
	}
});
