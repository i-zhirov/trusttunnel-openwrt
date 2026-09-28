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
		// The same shape as the status page's facts table: the generic
		// table/tr/td classes are what the LuCI theme styles, and the
		// label column stays left-aligned while the value cell carries
		// the content. The array around the value keeps a DOM node out
		// of E()'s second-argument position, which it would read as
		// attributes.
		var row = function(label, value) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'width:30%' }, label),
				E('td', { 'class': 'td' }, [value])
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
				E('table', { 'class': 'table cbi-section-table' }, [
					row(_('TrustTunnel package'), versionCell(versions ? versions.package : null)),
					row(_('Client package'), versionCell(versions ? versions.client_package : null)),
					row(_('Client binary'), versionCell(versions ? versions.client : null))
				])
			])
		]);
	}
});
