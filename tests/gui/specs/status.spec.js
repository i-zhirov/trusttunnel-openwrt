'use strict';

// Status view (status.js): verdict banner for each status shape, facts
// table, the Start/Stop/Restart actions, the rule preview modal for the
// effective profile (and the legacy do-not-bypass list), and the two 10 s
// polls.

const { test, expect } = require('@playwright/test');
const {
	openView, stubReset, stubSet, framesFor, waitForFrames, installClock, button
} = require('../helpers');

// The fields the view's verdict()/renderFacts() read.
const BASE = {
	enabled: true, running: true, mode: 'tun', device_up: true, rule: true,
	table: true, nft: true, client_installed: true,
	endpoint_hostname: 'vpn.example.com', addresses: [ '1.2.3.4:443' ],
	routing_profile: 'Default', routing_mode: 'vpn', vpn_mode: 'general',
	proxy_address: null, listener_up: null
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

test('proxy mode with a live listener shows the working verdict and the address', async ({ page }) => {
	await stubSet(page, {
		status: { ...BASE, mode: 'proxy', device: null, device_up: false,
		          listener_up: true, proxy_address: '0.0.0.0:1080' }
	});
	await openView(page, 'status');

	// Success verdicts render no banner; the facts carry the listener.
	await expect(page.locator('#view .alert-message')).toHaveCount(0);
	await expect(page.locator('#view')).toContainText('working');
	await expect(page.locator('#view code:has-text("0.0.0.0:1080")')).toHaveCount(1);
});

test('proxy mode without a live listener shows the warning verdict', async ({ page }) => {
	await stubSet(page, {
		status: { ...BASE, mode: 'proxy', device: null, device_up: false,
		          listener_up: false, proxy_address: '127.0.0.1:1080' }
	});
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

	await button(page, 'Enable').click();
	await waitForFrames(page, 'luci.trusttunnel', 'service', 1);
	let frames = await framesFor(page, 'luci.trusttunnel', 'service');
	expect(frames[0].args.action).toBe('start');
	await expect(page.locator('#maincontent .alert-message')).toContainText('Done');

	await button(page, 'Disable').click();
	await waitForFrames(page, 'luci.trusttunnel', 'service', 2);
	frames = await framesFor(page, 'luci.trusttunnel', 'service');
	expect(frames[1].args.action).toBe('stop');

	await button(page, 'Restart service').click();
	await waitForFrames(page, 'luci.trusttunnel', 'service', 3);
	frames = await framesFor(page, 'luci.trusttunnel', 'service');
	expect(frames[2].args.action).toBe('restart');
});

test('service failure surfaces a warning notification', async ({ page }) => {
	await stubSet(page, { service: { code: 0, output: 'boom', not_running: true } });
	await openView(page, 'status');

	await button(page, 'Enable').click();
	await expect(page.locator('#maincontent .alert-message.warning')).toContainText(
		'The service did not start. The client log below says why.');
});

test('Preview rules checks the assigned profile rule by rule', async ({ page }) => {
	// The stub's Default profile (vpn mode) carries bank.example as its
	// bypass list and telegram.org as its VPN list; the check_domain
	// golden for bank.example verdicts 'direct'.
	await openView(page, 'status');

	await button(page, 'Preview rules').click();
	const modal = page.locator('#modal_overlay .modal');
	await expect(modal).toContainText('Rule preview — Default');
	await expect(modal).toContainText(
		'How each rule of this profile is treated in VPN mode');

	// Only the effective list (the bypass list in vpn mode) is checked.
	await waitForFrames(page, 'luci.trusttunnel', 'check_domain', 1);
	let frames = await framesFor(page, 'luci.trusttunnel', 'check_domain');
	expect(frames.length).toBe(1);
	expect(frames[0].args.domain).toBe('bank.example');

	await expect(modal).toContainText('Bypassed by this profile');
	await expect(modal).toContainText('bank.example');
	await expect(modal).toContainText('direct');

	// The VPN list is inert in vpn mode and marked as such.
	await expect(modal).toContainText('No effect in VPN mode');
	await expect(modal).toContainText('telegram.org');
	await expect(modal).toContainText('no effect');
});

test('Preview rules without a profile shows the do-not-bypass list', async ({ page }) => {
	await stubSet(page, {
		status: { ...BASE, routing_profile: '', routing_mode: '', vpn_mode: 'general' },
		checkDomain: {
			domain: 'legacy.example', normalized: 'legacy.example',
			verdict: 'direct',
			reason: 'listed in the "do not bypass" list; the client sends it out by SNI'
		}
	});
	await openView(page, 'status');

	await button(page, 'Preview rules').click();
	const modal = page.locator('#modal_overlay .modal');
	await expect(modal).toContainText('Rule preview');
	await expect(modal).toContainText('No routing profile is assigned');

	await waitForFrames(page, 'luci.trusttunnel', 'check_domain', 1);
	const frames = await framesFor(page, 'luci.trusttunnel', 'check_domain');
	expect(frames[0].args.domain).toBe('legacy.example');

	await expect(modal).toContainText('The "do not bypass" list');
	await expect(modal).toContainText('legacy.example');
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

test('the client log shows a loading indicator until the first fetch', async ({ page }) => {
	await page.clock.install();
	await openView(page, 'status', { clock: true });

	// The first log fetch only fires at poll tick 10, so right after the
	// initial render the log section shows a spinner, not the log box.
	await expect(page.locator('#view .spinning')).toContainText('Loading');
	await expect(page.locator('#view pre')).toHaveCount(0);

	// Tick past 10 s: the first fetch replaces the spinner with the box
	// and later polls only refresh the text.
	await page.waitForTimeout(300);
	await page.clock.runFor(11500);
	await waitForFrames(page, 'luci.trusttunnel', 'log', 1);

	await expect(page.locator('#view .spinning')).toHaveCount(0);
	await expect(page.locator('#view pre')).toContainText('client started');
});
