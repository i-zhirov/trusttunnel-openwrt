'use strict';

// Client log view (log.js): the tail renders on the first paint (fetched
// during load(), no spinner state), and the 10 s poll refreshes it in
// place. The status page no longer fetches the log — status.spec.js pins
// that it stays away.

const { test, expect } = require('@playwright/test');
const {
	openView, stubReset, stubSet, framesFor, waitForFrames, clickButton
} = require('../helpers');

test.beforeEach(async ({ page }) => {
	await stubReset(page);
});

test('the log tail renders immediately on the first paint', async ({ page }) => {
	await page.clock.install();
	await stubSet(page, { log: { lines: [ 'first line' ] } });
	await openView(page, 'log', { clock: true });

	await expect(page.locator('#view h3')).toContainText('Client log');
	await expect(page.locator('#view pre')).toContainText('first line');

	// load() already fetched the tail: no spinner state on a page whose
	// whole purpose is the log.
	await expect(page.locator('#view .spinning')).toHaveCount(0);
	await expect(page.locator('#view')).toContainText('refreshed every ten seconds');
});

test('the 10 s poll refreshes the log in place', async ({ page }) => {
	await page.clock.install();
	await stubSet(page, { log: { lines: [ 'first line' ] } });
	await openView(page, 'log', { clock: true });

	// One fetch during load(); registering the poll restarts Poll with an
	// immediate tick-0 step, so a second fetch fires right away.
	const before = (await framesFor(page, 'luci.trusttunnel', 'log')).length;
	expect(before).toBe(2);
	expect((await framesFor(page, 'luci.trusttunnel', 'log'))[0].args.lines).toBe(80);

	// The tick-0 callback's promise must settle before fast-forwarding.
	await page.waitForTimeout(300);

	// 11 s of interval steps reach tick 10, firing the poll again with
	// the updated tail.
	await stubSet(page, { log: { lines: [ 'first line', 'second line' ] } });
	await page.clock.runFor(11500);
	await waitForFrames(page, 'luci.trusttunnel', 'log', before + 1);

	await expect(page.locator('#view pre')).toContainText('second line');
	await expect(page.locator('#view pre')).toContainText('first line');
});

test('Export client logs downloads the full tail', async ({ page }) => {
	await page.clock.install();
	await stubSet(page, { log: { lines: [ 'first line', 'second line' ] } });
	await openView(page, 'log', { clock: true });

	// The export fetches the whole ring buffer, not the 80-line
	// on-screen tail, and saves it as a timestamped text file.
	const downloadPromise = page.waitForEvent('download');
	await clickButton(page, 'Export client logs');
	const download = await downloadPromise;

	expect(download.suggestedFilename()).toMatch(/^trusttunnel-client-\d{8}-\d{6}\.log$/);

	const frames = await framesFor(page, 'luci.trusttunnel', 'log');
	expect(frames.filter(f => f.args.lines === 5000).length).toBe(1);

	const stream = await download.createReadStream();
	let text = '';
	for await (const chunk of stream)
		text += chunk;
	expect(text).toContain('first line');
	expect(text).toContain('second line');
});
