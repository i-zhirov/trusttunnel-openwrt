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

test('renders the tabs in order', async ({ page }) => {
	await openView(page, 'settings');

	// Six map-level tabs, keyed by the UCI section type...
	const tabs = page.locator('#view .cbi-map > .cbi-tabmenu li a');
	await expect(tabs).toHaveCount(6);
	await expect(tabs.nth(0)).toHaveText('General');
	await expect(tabs.nth(1)).toHaveText('Server');
	await expect(tabs.nth(2)).toHaveText('Proxy');
	await expect(tabs.nth(3)).toHaveText('Routing profiles');
	await expect(tabs.nth(4)).toHaveText('Advanced');
	await expect(tabs.nth(5)).toHaveText('Versions');

	// ...and every saved server splits into its own Connection/Security
	// inner tabs (map tabs key panes by section type, so two endpoint
	// sections would collide; section-level tabs use their own names).
	// The tab menu is inserted before each server's node — the first menu
	// belongs to the Default server.
	const innerTabs = page.locator('#view .cbi-section[data-tab="endpoint"] > .cbi-tabmenu').first().locator('li a');
	await expect(innerTabs).toHaveCount(2);
	await expect(innerTabs.nth(0)).toHaveText('Connection');
	await expect(innerTabs.nth(1)).toHaveText('Security');

	// The second saved server gets its own tab bar too.
	const backupTabs = page.locator('#view .cbi-section[data-tab="endpoint"] > .cbi-tabmenu').nth(1).locator('li a');
	await expect(backupTabs).toHaveCount(2);
});

test('switching tabs activates the corresponding pane', async ({ page }) => {
	await openView(page, 'settings');

	// Outer tabs: the Server pane is the endpoint section.
	await page.locator('#view .cbi-map > .cbi-tabmenu li a', { hasText: 'Server' }).click();
	await expect(page.locator('#view .cbi-section[data-tab="endpoint"]'))
		.toHaveAttribute('data-tab-active', 'true');
	await expect(page.locator('#view .cbi-section[data-tab="main"]'))
		.not.toHaveAttribute('data-tab-active', 'true');

	// Inner tabs of the Default server (the first tab menu).
	await page.locator('#view .cbi-section[data-tab="endpoint"] > .cbi-tabmenu').first()
		.locator('li a', { hasText: 'Security' }).click();
	await expect(page.locator('[id="container.trusttunnel.endpoint.security"]'))
		.toHaveAttribute('data-tab-active', 'true');
	await expect(page.locator('[id="container.trusttunnel.endpoint.connection"]'))
		.not.toHaveAttribute('data-tab-active', 'true');
});

test('fields render the loaded UCI state', async ({ page }) => {
	await openView(page, 'settings');

	// Flag widgets put the checkbox inside the option wrapper; Value and
	// ListValue inputs carry the `widget.`-prefixed id. The Default server
	// is the section named 'endpoint', so its field ids are unchanged.
	await expect(page.locator('[id="cbid.trusttunnel.main.enabled"] input[type="checkbox"]')).not.toBeChecked();
	await expect(page.locator('[id="widget.cbid.trusttunnel.endpoint.name"]')).toHaveValue('Default');
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

	// The second saved server renders its own field set.
	await expect(page.locator('[id="widget.cbid.trusttunnel.cfg02.name"]')).toHaveValue('Backup');
	await expect(page.locator('[id="widget.cbid.trusttunnel.cfg02.hostname"]')).toHaveValue('backup.example.com');

	// The active-server picker on the General tab lists every saved
	// server; the Default profile shows up in the per-server profile
	// select, alongside the "None" fallback entry.
	const active = page.locator('[id="widget.cbid.trusttunnel.main.endpoint"]');
	await expect(active.locator('option')).toHaveCount(2);
	await expect(active.locator('option[value="Default"]')).toHaveText('Default');
	await expect(active.locator('option[value="Backup"]')).toHaveText('Backup');

	const profile = page.locator('[id="widget.cbid.trusttunnel.endpoint.routing_profile"]');
	await expect(profile.locator('option[value=""]')).toHaveText('None — everything through the tunnel');
	await expect(profile.locator('option[value="Default"]')).toHaveText('Default');

	// The operation mode picker defaults to TUN and the Proxy tab carries
	// the listener defaults.
	await expect(page.locator('[id="widget.cbid.trusttunnel.main.mode"] option:checked'))
		.toHaveText('TUN — route the whole LAN');
	await expect(page.locator('[id="widget.cbid.trusttunnel.proxy.address"]'))
		.toHaveValue('127.0.0.1:1080');
});

test('the Versions tab reports the installed package versions', async ({ page }) => {
	await openView(page, 'settings');

	// The Versions pane is the UI-only 'about' section (map-level tabs
	// are keyed by the UCI section type). The values come from the
	// versions.json golden, served byte-identically to the backend
	// contract test.
	await page.locator('#view .cbi-map > .cbi-tabmenu li a', { hasText: 'Versions' }).click();
	const pane = page.locator('#view .cbi-section[data-tab="about"]');
	await expect(pane).toHaveAttribute('data-tab-active', 'true');

	await expect(pane.locator('.cbi-value')).toHaveCount(3);
	await expect(pane).toContainText('TrustTunnel package');
	await expect(pane).toContainText('1.0.15-r1');
	await expect(pane).toContainText('Client package');
	await expect(pane).toContainText('1.0.49-1');
	await expect(pane).toContainText('Client binary');
	await expect(pane).toContainText('1.1.5');
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

	await button(page, 'Import server config…').click();
	const modal = page.locator('#modal_overlay .modal');
	await expect(modal).toBeVisible();
	await modal.locator('textarea').fill(IMPORT_TEXT);
	await modal.locator('button', { hasText: 'Import' }).click();

	// The import handler flushes the pending values with uci.set + uci.save.
	await waitForFrames(page, 'uci', 'set', 1);
	await expect(page.locator('#maincontent .alert-message')).toContainText(
		'Import applied. Review the fields, then press Save & Apply.');

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

test('import shows a spinner on the button while the backend answers', async ({ page }) => {
	// Delay the import_config reply (stub state.delays) so the pending
	// state is observable: the Import button must be disabled and spinning
	// until the answer lands, not sitting there looking dead.
	await stubSet(page, { delays: { import_config: 800 } });
	await openView(page, 'settings');

	await button(page, 'Import server config…').click();
	const modal = page.locator('#modal_overlay .modal');
	await expect(modal).toBeVisible();
	await modal.locator('textarea').fill(IMPORT_TEXT);
	const importBtn = modal.locator('button', { hasText: 'Import' });
	await importBtn.click();

	// The handler flips the button synchronously on click; the reply is
	// held back 800 ms, so the pending state is observable.
	await expect(importBtn).toBeDisabled();
	await expect(importBtn).toContainText('Importing…');
	await expect(importBtn.locator('span.spinning')).toHaveCount(1);
	await expect(modal.locator('textarea')).toBeVisible();

	// Once the delayed answer arrives, the normal success flow runs.
	await waitForFrames(page, 'uci', 'set', 1);
	await expect(page.locator('#maincontent .alert-message')).toContainText(
		'Import applied. Review the fields, then press Save & Apply.');
});

test('import failure shows a danger notification', async ({ page }) => {
	await stubSet(page, { importResult: { error: 'could not parse the config' } });
	await openView(page, 'settings');

	await button(page, 'Import server config…').click();
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
		'Enter decimal or 0x-prefixed hex');
});

test('routing profile name uniqueness validator rejects duplicates', async ({ page }) => {
	await openView(page, 'settings');

	// Add a second profile and give it the same name as the seeded one.
	// (the section's Add button, not the DynamicList "+" buttons; scoped
	// to the routing_profile tab — the server sections carry name fields
	// too)
	await page.locator('#view .cbi-section[data-tab="routing_profile"] button[title="Add"]').click();
	const nameInputs = page.locator('#view .cbi-section[data-tab="routing_profile"] input[id$=".name"]');
	await expect(nameInputs).toHaveCount(2);
	await nameInputs.last().fill('Default');
	await button(page, 'Save').click();

	await expect(page.locator('#modal_overlay .modal')).toContainText(
		'Another profile already has this name');
});

test('server name uniqueness validator rejects duplicates', async ({ page }) => {
	await openView(page, 'settings');

	// Add a second server and give it the same name as the active one.
	await page.locator('#view .cbi-section[data-tab="endpoint"] button[title="Add"]').click();
	const nameInputs = page.locator('#view .cbi-section[data-tab="endpoint"] input[id$=".name"]');
	await expect(nameInputs).toHaveCount(3);
	await nameInputs.last().fill('Default');
	await button(page, 'Save').click();

	await expect(page.locator('#modal_overlay .modal')).toContainText(
		'Another server already has this name');
});

test('switching the active server stages main.endpoint', async ({ page }) => {
	await openView(page, 'settings');

	// The General-tab picker selects the ACTIVE server by name.
	await page.locator('[id="widget.cbid.trusttunnel.main.endpoint"]').selectOption('Backup');

	await page.locator('#view .cbi-page-actions .cbi-dropdown').first().click();
	await waitForFrames(page, 'uci', 'set', 1);
	await waitForFrames(page, 'http', '/admin/uci/apply_rollback', 1);

	const sets = await framesFor(page, 'uci', 'set');
	expect(sets[0].args.config).toBe('trusttunnel');
	expect(sets[0].args.section).toBe('main');
	expect(sets[0].args.values.endpoint).toBe('Backup');

	await waitForFrames(page, 'http', '/admin/uci/confirm', 1);
});

test('renaming the active server moves the selection with it', async ({ page }) => {
	await openView(page, 'settings');

	// Renaming the ACTIVE server must not leave main.endpoint pointing at
	// the old name — the tunnel would stop.
	await page.locator('[id="widget.cbid.trusttunnel.endpoint.name"]').fill('Home');

	await page.locator('#view .cbi-page-actions .cbi-dropdown').first().click();
	await waitForFrames(page, 'uci', 'set', 1);
	await waitForFrames(page, 'http', '/admin/uci/apply_rollback', 1);

	const sets = await framesFor(page, 'uci', 'set');
	const mainSet = sets.find(f => f.args.section === 'main');
	expect(mainSet.args.values.endpoint).toBe('Home');

	await waitForFrames(page, 'http', '/admin/uci/confirm', 1);
});

test('deleting the active server is refused while others remain', async ({ page }) => {
	await openView(page, 'settings');

	// The Default server is the active one; its Delete button must be
	// refused while the Backup server exists.
	const deletes = page.locator('#view .cbi-section[data-tab="endpoint"] .cbi-section-remove button');
	await expect(deletes).toHaveCount(2);
	await deletes.first().click();

	await expect(page.locator('#maincontent .alert-message.warning')).toContainText(
		'Select another active server on the General tab first');
	await expect(page.locator('[id="widget.cbid.trusttunnel.endpoint.name"]')).toHaveValue('Default');
});

test('deleting the last server saves the empty state', async ({ page }) => {
	await openView(page, 'settings');

	// Backup is not active: its Delete works. Then Default is the LAST
	// server and may be deleted too — the empty state is valid and saves
	// without a validation error.
	const deletes = page.locator('#view .cbi-section[data-tab="endpoint"] .cbi-section-remove button');
	await deletes.nth(1).click();
	await waitForFrames(page, 'uci', 'delete', 1);
	await deletes.first().click();
	await waitForFrames(page, 'uci', 'delete', 2);

	await page.locator('#view .cbi-page-actions .cbi-dropdown').first().click();
	await waitForFrames(page, 'http', '/admin/uci/apply_rollback', 1);
	await waitForFrames(page, 'http', '/admin/uci/confirm', 1);

	// No validation modal: the empty selection is allowed.
	await expect(page.locator('#modal_overlay .modal')).toHaveCount(0);
});
