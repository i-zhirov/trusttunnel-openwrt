'use strict';

// Diagnostics view (diagnostics.js): the diagnose chain render (grouped,
// problems first, toggle), DIAG_TEXT mapping, and the domain / ping /
// address-compare tools.

const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const {
	openView, stubReset, stubSet, framesFor, waitForFrames, button
} = require('../helpers');

// Byte-exact backend contract outputs, so the GUI tests see what the
// backend contract test pins.
const GOLDENS = path.resolve(__dirname, '../../backend/goldens');
const DIAGNOSE = JSON.parse(fs.readFileSync(path.join(GOLDENS, 'diagnose.json'), 'utf8'));
const HEALTHY = JSON.parse(fs.readFileSync(path.join(GOLDENS, 'healthy/diagnose.json'), 'utf8'));

const GROUP_ORDER = [ 'config', 'prereq', 'service', 'kernel', 'network' ];
const GROUP_TITLE = {
	config: 'Configuration', prereq: 'Prerequisites', service: 'Service',
	kernel: 'Kernel state', network: 'Network'
};

// Groups with at least one fail/warn check are rendered up front; the rest
// hide behind the toggle.
function visibleGroups(checks) {
	const withProblems = new Set(checks.filter(c => c.status === 'fail' || c.status === 'warn').map(c => c.group));
	return GROUP_ORDER.filter(g => withProblems.has(g)).map(g => GROUP_TITLE[g]);
}

function hiddenChecks(checks) {
	return checks.filter(c => c.status !== 'fail' && c.status !== 'warn');
}

test.beforeEach(async ({ page }) => {
	await stubReset(page);
});

test('diagnose renders the verdict banner with counts', async ({ page }) => {
	await openView(page, 'diagnostics');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	await expect(page.locator('#view .alert-message.danger')).toContainText('there are problems');
	await expect(page.locator('#view .alert-message.danger')).toContainText(
		'checks passed: ' + DIAGNOSE.counts.ok + ', remarks: ' + DIAGNOSE.counts.warn +
		', problems: ' + DIAGNOSE.counts.fail + ', skipped: ' + DIAGNOSE.counts.skip);
});

test('checks are grouped in the fixed order, problems first', async ({ page }) => {
	await openView(page, 'diagnostics');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	// The baked diagnose has fails/warns; the passed checks are hidden
	// behind the toggle, so the leading headers are exactly the groups
	// that contain a problem, in the fixed order (the hidden box's group
	// headers still exist in the DOM after them).
	const visible = visibleGroups(DIAGNOSE.checks);
	// Groups with passed checks are re-listed inside the hidden box, so a
	// mixed group can contribute two h4s (one visible, one hidden).
	const restGroups = new Set(hiddenChecks(DIAGNOSE.checks).map(c => c.group)).size;
	const h4 = page.locator('#view h4');
	await expect(h4).toHaveCount(visible.length + restGroups);
	for (let i = 0; i < visible.length; i++)
		await expect(h4.nth(i)).toHaveText(visible[i]);

	// A failing check renders its label and detail through DIAG_TEXT.
	await expect(page.locator('#view')).toContainText('Install kmod-tun.');

	// The passed checks are hidden until the toggle is pressed.
	const hidden = page.locator('#view div[style*="display:none"]');
	for (const c of hiddenChecks(DIAGNOSE.checks))
		await expect(hidden).toContainText(c.label);
});

test('toggle reveals the passed checks', async ({ page }) => {
	await openView(page, 'diagnostics');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	await button(page, 'Show the checks that passed').click();
	const hidden = page.locator('#view div[style*="display:none"]');
	await expect(hidden).toHaveCount(0);
	for (const c of hiddenChecks(DIAGNOSE.checks))
		await expect(page.locator('#view')).toContainText(c.label);
});

test('healthy diagnose shows the warn banner', async ({ page }) => {
	await stubSet(page, { diagnose: HEALTHY });
	await openView(page, 'diagnostics');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	await expect(page.locator('#view .alert-message.warning')).toContainText('works, with remarks');
});

test('Check again re-runs the diagnose chain', async ({ page }) => {
	await openView(page, 'diagnostics');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	await button(page, 'Check again').click();
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 2);
});

test('domain check renders the verdict table', async ({ page }) => {
	await openView(page, 'diagnostics');

	await page.locator('#view input[placeholder="youtube.com"]').fill('telegram.org');
	// exact:true — "Check again" contains "Check" as a substring
	await page.getByRole('button', { name: 'Check', exact: true }).click();
	await waitForFrames(page, 'luci.trusttunnel', 'check_domain', 1);

	const frames = await framesFor(page, 'luci.trusttunnel', 'check_domain');
	expect(frames[0].args.domain).toBe('telegram.org');

	await expect(page.locator('#view')).toContainText('Normalized');
	await expect(page.locator('#view')).toContainText('through the tunnel');
	await expect(page.locator('#view')).toContainText('direct');
});

test('ping renders loss and round-trip times', async ({ page }) => {
	await openView(page, 'diagnostics');

	await button(page, 'Ping').click();
	await waitForFrames(page, 'luci.trusttunnel', 'ping', 1);

	await expect(page.locator('#view')).toContainText('1.2.3.4');
	await expect(page.locator('#view')).toContainText('0%');
	await expect(page.locator('#view')).toContainText('10.1 / 12.3 / 15.7 ms');
});

test('address compare renders the tunnel and direct addresses', async ({ page }) => {
	await openView(page, 'diagnostics');

	await button(page, 'Compare').click();
	await waitForFrames(page, 'luci.trusttunnel', 'probe', 1);

	await expect(page.locator('#view')).toContainText('Through the tunnel');
	await expect(page.locator('#view')).toContainText('Directly');
	await expect(page.locator('#view code', { hasText: '203.0.113.77' })).toHaveCount(2);
});
