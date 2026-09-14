'use strict';

// Status view (status.js): verdict banner for each status shape, facts
// table, the Start/Stop/Restart actions and the two 10 s polls.

const { test, expect } = require('@playwright/test');
const {
	openView, stubReset, stubSet, framesFor, waitForFrames, installClock, button
} = require('../helpers');

// The fields the view's verdict()/renderFacts() read.
const BASE = {
	enabled: true, running: true, device_up: true, rule: true, table: true,
	nft: true, client_installed: true, endpoint_hostname: 'vpn.example.com',
	addresses: [ '1.2.3.4:443' ], routing_profile: 'Default',
	routing_mode: 'vpn', vpn_mode: 'general'
};

test.beforeEach(async ({ page }) => {
	await stubReset(page);
});

test('healthy status shows no banner, working state and facts', async ({ page }) => {
	await openView(page, 'status');

	await expect(page.locator('#view .alert-message')).toHaveCount(0);
	await expect(page.locator('#view')).toContainText('working');
	await expect(page.locator('#view')).toContainText(
		'Profile Default — VPN, everything except the bypass rules is tunneled');
	await expect(page.locator('#view code')).toContainText('vpn.example.com');
});

test('disabled service shows the info verdict', async ({ page }) => {
	await stubSet(page, { status: { ...BASE, enabled: false, running: false } });
	await openView(page, 'status');
	await expect(page.locator('#view .alert-message.info')).toContainText('The service is off');
});

test('enabled but stopped service shows the danger verdict', async ({ page }) => {
	await stubSet(page, { status: { ...BASE, running: false } });
	await openView(page, 'status');
	await expect(page.locator('#view .alert-message.danger')).toContainText(
		'The service is not running');
});

test('missing client binary shows the danger verdict', async ({ page }) => {
	await stubSet(page, { status: { ...BASE, client_installed: false } });
	await openView(page, 'status');
	await expect(page.locator('#view .alert-message.danger')).toContainText(
		'The TrustTunnel client is not installed');
});

test('client running without a tunnel device shows the warning verdict', async ({ page }) => {
	await stubSet(page, { status: { ...BASE, device_up: false } });
	await openView(page, 'status');
	await expect(page.locator('#view .alert-message.warning')).toContainText(
		'Connecting to vpn.example.com');
});

test('bypass profile shows the bypass success wording', async ({ page }) => {
	await stubSet(page, { status: { ...BASE, routing_profile: 'Bypass', routing_mode: 'bypass', vpn_mode: 'selective' } });
	await openView(page, 'status');

	// Success verdicts render no banner; the Mode fact carries the wording.
	await expect(page.locator('#view .alert-message')).toHaveCount(0);
	await expect(page.locator('#view')).toContainText(
		'Profile Bypass — bypass, only the VPN rules are tunneled');
});

test('verdict and facts render immediately, without waiting for the poll', async ({ page }) => {
	// Freeze the clock: the banner must be in the DOM from the initial
	// render. (The danger verdict means no State row, hence no 'working'.)
	await page.clock.install();
	await stubSet(page, { status: { ...BASE, running: false } });
	await openView(page, 'status', { clock: true });

	await expect(page.locator('#view .alert-message.danger')).toContainText(
		'The service is not running');
	await expect(page.locator('#view')).toContainText(
		'Profile Default — VPN, everything except the bypass rules is tunneled');
});

test('Start/Stop/Restart call the service method with the right action', async ({ page }) => {
	await openView(page, 'status');

	await button(page, 'Start').click();
	await waitForFrames(page, 'luci.trusttunnel', 'service', 1);
	let frames = await framesFor(page, 'luci.trusttunnel', 'service');
	expect(frames[0].args.action).toBe('start');
	await expect(page.locator('#maincontent .alert-message')).toContainText('Done');

	await button(page, 'Stop').click();
	await waitForFrames(page, 'luci.trusttunnel', 'service', 2);
	frames = await framesFor(page, 'luci.trusttunnel', 'service');
	expect(frames[1].args.action).toBe('stop');

	await button(page, 'Restart').click();
	await waitForFrames(page, 'luci.trusttunnel', 'service', 3);
	frames = await framesFor(page, 'luci.trusttunnel', 'service');
	expect(frames[2].args.action).toBe('restart');
});

test('service failure surfaces a warning notification', async ({ page }) => {
	await stubSet(page, { service: { code: 0, output: 'boom', not_running: true } });
	await openView(page, 'status');

	await button(page, 'Start').click();
	await expect(page.locator('#maincontent .alert-message.warning')).toContainText(
		'The service did not start. The client log below says why.');
});

test('the 10 s polls refresh the verdict and fetch the client log', async ({ page }) => {
	await page.clock.install();
	await openView(page, 'status', { clock: true });

	// The initial render does one status call (from load()). Registering
	// the first poll callback restarts Poll with an immediate tick-0 step,
	// so the status poll fires once right away — but the log callback is
	// only queued after that step, so it waits for tick 10.
	const before = (await framesFor(page, 'luci.trusttunnel', 'status')).length;
	expect(before).toBe(2);

	// The tick-0 callback's promise must settle (its e.r flag resets via
	// .finally) before fast-forwarding, or tick 10 will skip it.
	await page.waitForTimeout(300);

	// 11 s of interval steps reach tick 10, firing both callbacks again.
	// runFor (not fastForward) also fires the intermediate rAFs, which the
	// RPC batch flush depends on.
	await page.clock.runFor(11500);
	await waitForFrames(page, 'luci.trusttunnel', 'status', before + 1);
	await waitForFrames(page, 'luci.trusttunnel', 'log', 1);

	const logFrames = await framesFor(page, 'luci.trusttunnel', 'log');
	expect(logFrames[0].args.lines).toBe(80);

	await expect(page.locator('#view pre')).toContainText('client started');
});
