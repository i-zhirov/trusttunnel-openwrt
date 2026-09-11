'use strict';
let m = require('luci.trusttunnel');
let api = m['luci.trusttunnel'];
let name = ARGV[0];
let args = length(ARGV[1]) ? json(ARGV[1]) : {};
let out = api[name].call({ args: args });
// checked_at is a "now" timestamp: normalize it so the golden comparison
// is not time-dependent. null stays null (no fetch happened).
if (type(out) == 'object' && 'checked_at' in out && out.checked_at != null)
	out.checked_at = 0;
// The tun device's carrier sysfs read is not stable (it can be 0, 1 or
// EINVAL depending on kernel timing): normalize the diagnose entry so the
// golden comparison does not depend on it. The carrier branch itself is
// pinned by the state-matrix comparison (ok 'up' when 1, warn otherwise).
if (type(out) == 'object' && type(out.checks) == 'array') {
	for (let c in out.checks) {
		if (c.label == 'Tunnel carrier') {
			c.status = 'warn';
			c.detail = 'no carrier';
			c.hint = 'The device exists but the client has not established the tunnel yet. This is the client side, not the routing — read the client log.';
		}
	}
	// The counts are computed by the backend before this normalization:
	// recompute them so the golden comparison stays consistent.
	let counts = { ok: 0, warn: 0, fail: 0, skip: 0 };
	for (let c in out.checks)
		counts[c.status]++;
	out.counts = counts;
}
print(sprintf('%J', out));
