'use strict';

import { readfile } from 'fs';

// Shared constants and records helpers for the luci.trusttunnel rpcd
// backend. The backend is the only ucode consumer today, but the records
// schema is a hard contract shared with the shell side (records.sh in
// /usr/libexec/trusttunnel), so the parser and the fixed paths live here
// once instead of being re-implemented per method or per future backend
// object.
//
// The constants mirror records.sh's tt_*_DEFAULT values: changing a path
// or a kernel default here is a contract change that must land on the
// shell side too.
export const LIBDIR = '/usr/libexec/trusttunnel';
export const OUTDIR = '/var/etc/trusttunnel';
export const RECORDS = OUTDIR + '/settings.tsv';
export const CLIENT = '/opt/trusttunnel_client/trusttunnel_client';
export const DEV_STATS = '/proc/net/dev';
export const TABLE_DEFAULT = '880';

// Parse the records TSV (section.option<TAB>value, one line per list
// value) into a key -> array map. Lines without a tab separator are
// skipped; the path defaults to the shipped records location.
export function load_records(path) {
	if (path == null)
		path = RECORDS;

	let raw = readfile(path);
	let out = {};

	if (raw == null)
		return out;

	let lines = split(raw, '\n');
	for (let i = 0; i < length(lines); i++) {
		let line = lines[i];
		let t = index(line, '\t');
		if (t < 0)
			continue;

		let key = substr(line, 0, t);
		let value = substr(line, t + 1);
		if (!(key in out))
			out[key] = [];
		push(out[key], value);
	}

	return out;
};

// First value for a key, or the default when the key is absent or its
// first value is empty.
export function first(rec, key, dflt) {
	let v = rec[key];
	return length(v) && length(v[0]) ? v[0] : dflt;
};

// The operation mode of the applied config: true when main.mode is
// "proxy". Absent main.mode means tun — the default and the only mode of
// earlier versions. Mirrors records.sh's tt_mode_is_proxy.
export function mode_is_proxy(rec) {
	return first(rec, 'main.mode', 'tun') == 'proxy';
};
