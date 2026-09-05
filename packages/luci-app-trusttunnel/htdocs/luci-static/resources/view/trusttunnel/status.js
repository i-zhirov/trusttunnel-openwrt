'use strict';

'require view';
'require poll';
'require rpc';
'require ui';
'require dom';

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

		if (!st.device_up)
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

		if (st.routing_profile)
			return {
				level: 'success',
				head: host ? _('Tunnel works, profile %s — everything except the bypass rules goes through %s').format(st.routing_profile, host)
				           : _('Tunnel works, profile %s — everything except the bypass rules goes through the tunnel').format(st.routing_profile),
				detail: _('The bypass rules are sent out directly.')
			};

		return {
			level: 'success',
			head: host ? _('All LAN traffic goes through %s').format(host) : _('All LAN traffic goes through the tunnel'),
			detail: _('Domains from the "do not bypass" list are sent out directly.')
		};
	},

	renderVerdict: function(st) {
		var v = this.verdict(st);

		if (v.level === 'success')
			return E('div');

		return E('div', { 'class': 'alert-message ' + v.level },
			E('strong', v.head),
			v.detail ? E('br') : null,
			v.detail ? v.detail : null);
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

	renderFacts: function(st) {
		var rows = [];

		if (this.verdict(st).level === 'success')
			rows.push(this.row(_('State'), E('span', { 'style': 'color:#57bc48;font-weight:bold' }, _('working'))));

		if (st.routing_profile) {
			if (st.routing_mode === 'bypass')
				rows.push(this.row(_('Mode'), _('Profile %s — bypass, only the VPN rules are tunneled').format(st.routing_profile)));
			else
				rows.push(this.row(_('Mode'), _('Profile %s — VPN, everything except the bypass rules is tunneled').format(st.routing_profile)));
		}
		else {
			rows.push(this.row(_('Mode'), _('Everything through VPN')));
		}

		if (st.endpoint_hostname)
			rows.push(this.row(_('Server'), E('code', st.endpoint_hostname)));

		return E('table', { 'class': 'table' }, rows);
	},

	handleAction: function(action, ev) {
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

	load: function() {
		return callStatus();
	},

	render: function(st) {
		var self = this;

		var verdictBox = E('div', this.renderVerdict(st));
		var factsBox = E('div', this.renderFacts(st));
		var logBox = E('pre', { 'style': 'max-height:22em;overflow:auto;margin:0' });

		poll.add(function() {
			return callStatus().then(function(s) {
				dom.content(verdictBox, self.renderVerdict(s));
				dom.content(factsBox, self.renderFacts(s));
			});
		}, 10);

		poll.add(function() {
			return callLog(80).then(function(r) {
				logBox.textContent = (r.lines || []).join('\n');
			});
		}, 10);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'class': 'cbi-map-title' }, _('TrustTunnel')),
			E('div', { 'class': 'cbi-section' }, [
				verdictBox,
				E('div', [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': function(ev) { self.handleAction('start', ev); }
					}, _('Start')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-reset',
						'click': function(ev) { self.handleAction('stop', ev); }
					}, _('Stop')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function(ev) { self.handleAction('restart', ev); }
					}, _('Restart'))
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Now')),
				factsBox
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', _('Client log')),
				logBox
			])
		]);
	}
});
