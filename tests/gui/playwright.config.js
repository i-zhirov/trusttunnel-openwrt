'use strict';

// Playwright config for the LuCI GUI tests. run.sh starts the stub server
// and executes: node node_modules/@playwright/test/cli.js test -c tests/gui
// The browser (chromium) ships in the pinned mcr.microsoft.com/playwright
// image; node_modules is mounted from the host via the repo mount.

module.exports = {
	testDir: __dirname + '/specs',
	outputDir: __dirname + '/.artifacts',
	timeout: 30000,
	workers: 1,
	retries: 0,
	reporter: [ [ 'list' ] ],
	use: {
		baseURL: 'http://127.0.0.1:' + (process.env.STUB_PORT || 8123),
		trace: 'off', // LuCI forms carry password fields; never trace
		screenshot: 'off',
		video: 'off'
	}
};
