'use strict';

// Shared helpers for the LuCI GUI specs.
//
// The stub server (tests/gui/stub/server.js) holds all router state and
// records every RPC frame; the specs drive the real views in a real browser
// and assert both on the rendered DOM and on the frames the stub recorded.

const { expect } = require('@playwright/test');

const VIEWS = [ 'status', 'settings', 'diagnostics' ];
const VIEW_URL = view => '/cgi-bin/luci/admin/services/trusttunnel/' + view;

// All three views render a .cbi-map root after their load()/render() cycle.
// With a fake clock installed (page.clock.install()), the rAF-batched RPC
// flush needs a small time advance before the view can render; 100 ms is
// far below the 1 s poll step, so no poll callback fires during open.
async function openView(page, view, opts = {}) {
	await page.goto(VIEW_URL(view));
	if (opts.clock)
		await page.clock.runFor(100);
	await page.locator('.cbi-map').first().waitFor({ state: 'attached' });
	if (opts.clock)
		await page.clock.runFor(100);
}

async function stubControl(page, cmd) {
	const res = await page.request.post('/__stub', { data: cmd });
	expect(res.ok(), 'stub control ' + JSON.stringify(cmd)).toBeTruthy();
}

async function stubSet(page, setObj) {
	await stubControl(page, { set: setObj });
}

async function stubReset(page) {
	await stubControl(page, { reset: true });
}

async function stubState(page) {
	const res = await page.request.get('/__stub');
	expect(res.ok(), 'stub state fetch').toBeTruthy();
	return res.json();
}

async function frames(page) {
	return (await stubState(page)).frames;
}

// Frames for one RPC method, newest last.
async function framesFor(page, object, method) {
	const all = await frames(page);
	return all.filter(f => f.object === object && f.method === method);
}

// Wait until the stub has recorded `count` calls of object.method (polling
// beats fixed sleeps: the RPC batch flush is rAF-timed in the browser).
async function waitForFrames(page, object, method, count) {
	let got = 0;
	for (let i = 0; i < 50; i++) {
		got = (await framesFor(page, object, method)).length;
		if (got >= count)
			return;
		await page.waitForTimeout(100);
	}
	expect(got, `stub recorded ${count}x ${object}.${method}`).toBeGreaterThanOrEqual(count);
}

// The status view registers two 10 s polls; drive them with Playwright's
// fake clock instead of waiting real time.
async function installClock(page) {
	await page.clock.install();
}

// Fail the test on uncaught browser errors; benign noise (resource 404s,
// the cgi-exec probe) is filtered.
function watchErrors(page) {
	const errors = [];
	page.on('pageerror', e => errors.push('pageerror: ' + e.message));
	return errors;
}

// A <button> with the given visible text inside the #view container.
function button(page, text) {
	return page.locator('#view button', { hasText: text }).first();
}

module.exports = {
	VIEWS, VIEW_URL, openView, stubControl, stubSet, stubReset, stubState,
	frames, framesFor, waitForFrames, installClock, watchErrors, button
};
