'use strict';

// Versions view (versions.js): what is installed, read-only. The values
// come from the versions.json golden, served byte-identically to the
// backend contract test.

const { test, expect } = require('@playwright/test');
const { openView, stubReset, framesFor } = require('../helpers');

test.beforeEach(async ({ page }) => {
	await stubReset(page);
});

test('reports the installed package versions', async ({ page }) => {
	await openView(page, 'versions');

	// The values come from the backend, not from UCI: the page must have
	// asked for them.
	await expect.poll(() => framesFor(page, 'luci.trusttunnel', 'versions')).toHaveLength(1);

	await expect(page.locator('#view .cbi-section-table')).toContainText('TrustTunnel package');
	await expect(page.locator('#view .cbi-section-table')).toContainText('1.0.15-r1');
	await expect(page.locator('#view .cbi-section-table')).toContainText('Client package');
	await expect(page.locator('#view .cbi-section-table')).toContainText('1.1.7-1');
	await expect(page.locator('#view .cbi-section-table')).toContainText('Client binary');
	await expect(page.locator('#view .cbi-section-table')).toContainText('1.1.7');
});
