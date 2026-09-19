'use strict';

// Diagnostics view (diagnostics.js): the diagnose chain render (grouped,
// problems first, toggle), DIAG_TEXT mapping, and the domain / ping /
// address-compare tools.

const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const {
	openView, stubReset, stubSet, framesFor, waitForFrames, clickButton
} = require('../helpers');

// Byte-exact backend contract outputs, so the GUI tests see what the
// backend contract test pins.
const GOLDENS = path.resolve(__dirname, '../../backend/goldens');
const DIAGNOSE = JSON.parse(fs.readFileSync(path.join(GOLDENS, 'diagnose.json'), 'utf8'));
const HEALTHY = JSON.parse(fs.readFileSync(path.join(GOLDENS, 'healthy/diagnose.json'), 'utf8'));

const GROUP_ORDER = [ 'config', 'prereq', 'service', 'kernel', 'network' ];
const GROUP_TITLE = {
	config: 'Configuration', prereq: 'Prerequisites', service: 'Service state',
	kernel: 'Kernel state', network: 'Connectivity'
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

test('opening the view does not run the checks', async ({ page }) => {
	await openView(page, 'diagnostics');

	// The chain runs on demand only: no diagnose frame until the button is
	// pressed, and the box explains that nothing ran yet.
	expect(await framesFor(page, 'luci.trusttunnel', 'diagnose')).toHaveLength(0);
	await expect(page.locator('#view')).toContainText('not run yet');
});

test('diagnose renders the verdict banner with counts', async ({ page }) => {
	await openView(page, 'diagnostics');

	await clickButton(page, 'Run checks');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	await expect(page.locator('#view .alert-message.danger')).toContainText('there are problems');
	await expect(page.locator('#view .alert-message.danger')).toContainText(
		'checks passed: ' + DIAGNOSE.counts.ok + ', remarks: ' + DIAGNOSE.counts.warn +
		', problems: ' + DIAGNOSE.counts.fail + ', skipped: ' + DIAGNOSE.counts.skip);
});

test('checks are grouped in the fixed order, problems first', async ({ page }) => {
	await openView(page, 'diagnostics');

	await clickButton(page, 'Run checks');
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
	await expect(page.locator('#view')).toContainText('Install the kmod-tun package.');

	// The passed checks are hidden until the toggle is pressed.
	const hidden = page.locator('#view div[style*="display:none"]');
	for (const c of hiddenChecks(DIAGNOSE.checks))
		await expect(hidden).toContainText(c.label);
});

test('toggle reveals the passed checks', async ({ page }) => {
	await openView(page, 'diagnostics');

	await clickButton(page, 'Run checks');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	await clickButton(page, 'Show the checks that passed');
	const hidden = page.locator('#view div[style*="display:none"]');
	await expect(hidden).toHaveCount(0);
	for (const c of hiddenChecks(DIAGNOSE.checks))
		await expect(page.locator('#view')).toContainText(c.label);
});

test('healthy diagnose shows the warn banner', async ({ page }) => {
	await stubSet(page, { diagnose: HEALTHY });
	await openView(page, 'diagnostics');

	await clickButton(page, 'Run checks');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	await expect(page.locator('#view .alert-message.warning')).toContainText('works, with remarks');
});

test('Run checks re-runs the diagnose chain', async ({ page }) => {
	await openView(page, 'diagnostics');

	await clickButton(page, 'Run checks');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 1);

	await clickButton(page, 'Run checks');
	await waitForFrames(page, 'luci.trusttunnel', 'diagnose', 2);
});
