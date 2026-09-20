'use strict';

// Tools view (tools.js): the ad-hoc helpers that moved off the
// Diagnostics page — domain verdict check, endpoint ping and the
// tunnel-vs-direct address comparison. Each runs only on demand.

const { test, expect } = require('@playwright/test');
const {
	openView, stubReset, framesFor, waitForFrames, clickButton
} = require('../helpers');

test.beforeEach(async ({ page }) => {
	await stubReset(page);
});

test('domain check renders the verdict table', async ({ page }) => {
	await openView(page, 'tools');

	await page.locator('#view input[placeholder="youtube.com"]').fill('telegram.org');
	await clickButton(page, 'Run checks');
	await waitForFrames(page, 'luci.trusttunnel', 'check_domain', 1);

	const frames = await framesFor(page, 'luci.trusttunnel', 'check_domain');
	expect(frames[0].args.domain).toBe('telegram.org');

	await expect(page.locator('#view')).toContainText('Normalized');
	await expect(page.locator('#view')).toContainText('through the tunnel');
	await expect(page.locator('#view')).toContainText('direct');
});

test('ping renders loss and round-trip times', async ({ page }) => {
	await openView(page, 'tools');

	await clickButton(page, 'Ping server');
	await waitForFrames(page, 'luci.trusttunnel', 'ping', 1);

	await expect(page.locator('#view')).toContainText('1.2.3.4');
	await expect(page.locator('#view')).toContainText('0%');
	await expect(page.locator('#view')).toContainText('10.1 / 12.3 / 15.7 ms');
});

test('address compare renders the tunnel and direct addresses', async ({ page }) => {
	await openView(page, 'tools');

	await clickButton(page, 'Compare addresses');
	await waitForFrames(page, 'luci.trusttunnel', 'probe', 1);

	await expect(page.locator('#view')).toContainText('Through the tunnel');
	await expect(page.locator('#view')).toContainText('Directly');
	await expect(page.locator('#view code', { hasText: '203.0.113.77' })).toHaveCount(2);
});
