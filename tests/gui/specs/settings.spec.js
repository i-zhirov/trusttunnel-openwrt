'use strict';

// Settings view (settings.js): the tabbed form.Map, field rendering from the
// loaded UCI state, the Import modal flow, Save & Apply and the inline
// validators.

const { test, expect } = require('@playwright/test');
const {
	openView, stubReset, stubSet, framesFor, waitForFrames, button
} = require('../helpers');

const IMPORT_TEXT = 'endpoint = "vpn.example.com:443"';

test.beforeEach(async ({ page }) => {
	await stubReset(page);
});

test('renders the four tabs in order', async ({ page }) => {
	await openView(page, 'settings');

	const tabs = page.locator('#view .cbi-tabmenu li a');
	await expect(tabs).toHaveCount(4);
	await expect(tabs.nth(0)).toHaveText('General');
	await expect(tabs.nth(1)).toHaveText('Server');
	await expect(tabs.nth(2)).toHaveText('Routing profiles');
	await expect(tabs.nth(3)).toHaveText('Network');
});

test('switching tabs activates the corresponding pane', async ({ page }) => {
	await openView(page, 'settings');

	await page.locator('#view .cbi-tabmenu li a', { hasText: 'Server' }).click();
	await expect(page.locator('#view .cbi-section[data-tab="endpoint"]'))
		.toHaveAttribute('data-tab-active', 'true');
	await expect(page.locator('#view .cbi-section[data-tab="main"]'))
		.not.toHaveAttribute('data-tab-active', 'true');
});

test('fields render the loaded UCI state', async ({ page }) => {
	await openView(page, 'settings');

	// Flag widgets put the checkbox inside the option wrapper; Value and
	// ListValue inputs carry the `widget.`-prefixed id.
	await expect(page.locator('[id="cbid.trusttunnel.main.enabled"] input[type="checkbox"]')).not.toBeChecked();
	await expect(page.locator('[id="widget.cbid.trusttunnel.endpoint.hostname"]')).toHaveValue('vpn.example.com');
	await expect(page.locator('[id="widget.cbid.trusttunnel.endpoint.username"]')).toHaveValue('alice');
	await expect(page.locator('[id="widget.cbid.trusttunnel.endpoint.password"]')).toHaveAttribute('type', 'password');
	await expect(page.locator('[id="widget.cbid.trusttunnel.endpoint.protocol"] option:checked')).toHaveText('HTTP/2');
	await expect(page.locator('[id="widget.cbid.trusttunnel.network.mtu"]')).toHaveValue('1350');
	await expect(page.locator('[id="widget.cbid.trusttunnel.network.fwmark"]')).toHaveValue('0x9527');
	await expect(page.locator('[id="cbid.trusttunnel.endpoint.address"]')).toContainText('203.0.113.10:443');
	await expect(page.locator('[id="widget.cbid.trusttunnel.endpoint.protocol"] option:checked')).toHaveText('HTTP/2');
	await expect(page.locator('[id="widget.cbid.trusttunnel.network.mtu"]')).toHaveValue('1350');
	await expect(page.locator('[id="widget.cbid.trusttunnel.network.fwmark"]')).toHaveValue('0x9527');

	// The Default profile seeded by uci-defaults shows up in the select,
	// alongside the "None" fallback entry.
	const profile = page.locator('[id="widget.cbid.trusttunnel.endpoint.routing_profile"]');
	await expect(profile.locator('option')).toHaveCount(2);
	await expect(profile.locator('option[value="Default"]')).toHaveText('Default');
});

test('import applies the parsed fields to the pending save', async ({ page }) => {
	await stubSet(page, {
		importResult: {
			hostname: 'vpn.example.com', username: 'alice', password: 'secret',
			addresses: [ '203.0.113.10:443' ], protocol: 'http2', anti_dpi: true,
			has_ipv6: true, skip_verification: false, certificate: 'CERT',
			custom_sni: 'sni.example.com', client_random: '0a0b0c/0f0f0f',
			dns_upstreams: [ '94.140.14.14' ]
		}
	});
	await openView(page, 'settings');

	await button(page, 'Import…').click();
	const modal = page.locator('#modal_overlay .modal');
	await expect(modal).toBeVisible();
	await modal.locator('textarea').fill(IMPORT_TEXT);
	await modal.locator('button', { hasText: 'Import' }).click();

	// The import handler flushes the pending values with uci.set + uci.save.
	await waitForFrames(page, 'uci', 'set', 1);
	await expect(page.locator('#maincontent .alert-message')).toContainText(
		'Imported. Review the fields and press Save & Apply.');

	const sets = await framesFor(page, 'uci', 'set');
	const endpoint = sets[0].args.values;
	expect(sets[0].args.config).toBe('trusttunnel');
	expect(sets[0].args.section).toBe('endpoint');
	expect(endpoint.hostname).toBe('vpn.example.com');
	expect(endpoint.username).toBe('alice');
	expect(endpoint.password).toBe('secret');
	expect(endpoint.certificate).toBe('CERT');
	expect(endpoint.address).toEqual([ '203.0.113.10:443' ]);
	expect(endpoint.custom_sni).toBe('sni.example.com');
	expect(endpoint.client_random).toBe('0a0b0c/0f0f0f');
	expect(endpoint.protocol).toBe('http2');
	expect(endpoint.dns_upstream).toEqual([ '94.140.14.14' ]);
});

test('import failure shows a danger notification', async ({ page }) => {
	await stubSet(page, { importResult: { error: 'could not parse the config' } });
	await openView(page, 'settings');

	await button(page, 'Import…').click();
	const modal = page.locator('#modal_overlay .modal');
	await modal.locator('textarea').fill('garbage');
	await modal.locator('button', { hasText: 'Import' }).click();

	await expect(page.locator('#maincontent .alert-message.danger')).toContainText(
		'could not parse the config');
});

test('Save & Apply persists a field change through the stub', async ({ page }) => {
	await openView(page, 'settings');

	// Enable "Start on boot": stages main.enabled='1' in the pending save.
	await page.locator('[id="cbid.trusttunnel.main.enabled"] input[type="checkbox"]').check();

	// Save & Apply is a ComboButton — a .cbi-dropdown div in the page
	// footer, not a <button>. (The dns_upstream preset list is also a
	// .cbi-dropdown, so scope to the footer.)
	await page.locator('#view .cbi-page-actions .cbi-dropdown').first().click();
	await waitForFrames(page, 'uci', 'set', 1);
	await waitForFrames(page, 'http', '/admin/uci/apply_rollback', 1);

	const sets = await framesFor(page, 'uci', 'set');
	expect(sets[0].args.config).toBe('trusttunnel');
	expect(sets[0].args.section).toBe('main');
	expect(sets[0].args.values.enabled).toBe('1');

	// The apply flow then polls the confirm endpoint.
	await waitForFrames(page, 'http', '/admin/uci/confirm', 1);
});

test('fwmark validator rejects a non-hexadecimal value', async ({ page }) => {
	await openView(page, 'settings');

	await page.locator('[id="widget.cbid.trusttunnel.network.fwmark"]').fill('zzz');
	await button(page, 'Save').click();

	await expect(page.locator('#modal_overlay .modal')).toContainText(
		'Enter a decimal number or 0x-prefixed hexadecimal');
});

test('routing profile name uniqueness validator rejects duplicates', async ({ page }) => {
	await openView(page, 'settings');

	// Add a second profile and give it the same name as the seeded one.
	// (the section's Add button, not the DynamicList "+" buttons)
	await page.locator('#view .cbi-section[data-tab="routing_profile"] button[title="Add"]').click();
	const nameInputs = page.locator('#view input[id^="widget.cbid.trusttunnel."][id$=".name"]');
	await expect(nameInputs).toHaveCount(2);
	await nameInputs.last().fill('Default');
	await button(page, 'Save').click();

	await expect(page.locator('#modal_overlay .modal')).toContainText(
		'Another profile already has this name');
});
