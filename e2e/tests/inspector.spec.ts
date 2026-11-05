import type { Page } from '@playwright/test';

import { type App, created, expect, png, test, todo, todoUrl, user } from './support';

const todoResult = `200 (${todo.length} bytes)`;

test.describe('list and detail', () => {
  test('a call is listed, opens, and copies as cURL', async ({ app, page }) => {
    await app.tap('GET JSON', todoResult);

    await app.openInspector();
    const row = app.row('GET', '/todos/1', 'jsonplaceholder.typicode.com', '200');
    await expect(row).toBeVisible();
    await row.click();

    await expect(page.getByRole('tab', { name: 'Response' })).toBeVisible();
    await expect(app.text('delectus aut autem')).toBeVisible();

    await app.button('Copy').click();
    await page.getByRole('menuitem', { name: 'Copy cURL' }).click();
    await expect(app.text('cURL copied')).toBeVisible();
    const clipboard = await page.evaluate(() => navigator.clipboard.readText());
    expect(clipboard).toBe(`curl '${todoUrl}'`);
  });

  test('every demo button is captured', async ({ app, net, page }) => {
    await app.tap('GET JSON', todoResult);
    await app.tap('POST JSON', `201 (${created.length} bytes)`);
    await app.tap('404', '404 (0 bytes)');
    await app.tap('500', '500 (0 bytes)');
    await app.tap('Big JSON (5 MB)', /^200 \(\d{7} bytes\)$/);
    await app.tap('Image', `200 (${png.length} bytes)`);
    await app.tap('Dio GET', `200 (${user.length} bytes)`);
    // Big JSON was answered by its rule: nothing asked for its URL.
    expect(net.unexpected).toEqual([]);
    const post = net.received.find((r) => r.method() === 'POST');
    expect(post?.postDataJSON()).toEqual({ title: 'Proxie', body: 'demo', userId: 1 });

    await app.openInspector();
    await expect(app.row('GET', '/todos/1', '200')).toBeVisible();
    await expect(app.row('POST', '/posts', '201')).toBeVisible();
    await expect(app.row('GET', '/status/404', '404')).toBeVisible();
    await expect(app.row('GET', '/status/500', '500')).toBeVisible();
    await expect(app.row('GET', '/data.json', 'big-json.invalid', 'MAP', '200')).toBeVisible();
    await expect(app.row('GET', '/image/png', '200')).toBeVisible();
    await expect(app.row('GET', '/users/1', '200')).toBeVisible();

    // Adapter chips: the web has no dart:io, and http needs no attaching.
    await expect(page.getByRole('checkbox', { name: 'io', exact: true })).toBeHidden();
    await page.getByRole('checkbox', { name: 'http', exact: true }).click();
    await expect(app.row('/todos/1')).toBeVisible();
    await expect(app.row('/users/1')).toBeHidden();
    await page.getByRole('checkbox', { name: 'http', exact: true }).click();
    await page.getByRole('checkbox', { name: 'dio', exact: true }).click();
    await expect(app.row('/users/1')).toBeVisible();
    await expect(app.row('/todos/1')).toBeHidden();
    await page.getByRole('checkbox', { name: 'dio', exact: true }).click();
    await expect(app.row('/todos/1')).toBeVisible();

    // The 5 MB body opens as a tree.
    await app.row('/data.json').click();
    await expect(app.text(/generated: true/)).toBeVisible({ timeout: 30_000 });
  });

  test('switching from Big JSON to a small body shows its rows', async ({ app, page }, testInfo) => {
    await app.tap('GET JSON', todoResult);
    await app.tap('Big JSON (5 MB)', /^200 \(\d{7} bytes\)$/);
    await app.openInspector();

    // Three times: the first open parses the body, later ones reuse it.
    for (const round of [1, 2, 3]) {
      await app.row('/data.json').click();
      await expect(app.text(/generated: true/)).toBeVisible({ timeout: 30_000 });

      const clicked = Date.now();
      await app.row('/todos/1').click();
      await expect(app.text('delectus aut autem')).toBeVisible();
      testInfo.annotations.push({ type: 'rows-visible-ms', description: `round ${round}: ${Date.now() - clicked}` });
      await expect(app.text(/generated: true/)).toBeHidden();
    }

    // Without waiting for the big tree first.
    await app.row('/data.json').click();
    const clicked = Date.now();
    await app.row('/todos/1').click();
    await expect(app.text('delectus aut autem')).toBeVisible();
    testInfo.annotations.push({ type: 'rows-visible-ms', description: `immediate: ${Date.now() - clicked}` });
    await expect(page.getByRole('tab', { name: 'Response' })).toBeVisible();
  });

  test('Errors shows only 4xx and 5xx', async ({ app, page }) => {
    await app.tap('GET JSON', todoResult);
    await app.tap('POST JSON', `201 (${created.length} bytes)`);
    await app.tap('404', '404 (0 bytes)');
    await app.tap('500', '500 (0 bytes)');
    await app.openInspector();
    await expect(app.row('/todos/1')).toBeVisible();

    await page.getByRole('checkbox', { name: 'Errors' }).click();
    await expect(app.row('/status/404', '404')).toBeVisible();
    await expect(app.row('/status/500', '500')).toBeVisible();
    await expect(app.row('/todos/1')).toBeHidden();
    await expect(app.row('/posts')).toBeHidden();

    await page.getByRole('checkbox', { name: 'Errors' }).click();
    await expect(app.row('/todos/1')).toBeVisible();
    await expect(app.row('/posts')).toBeVisible();
  });
});

test.describe('layout', () => {
  test('1280x800 shows list and detail side by side', async ({ app, page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await app.tap('GET JSON', todoResult);
    await app.openInspector();

    await expect(app.text('Select a request')).toBeVisible();
    await app.row('/todos/1').click();
    await expect(page.getByRole('tab', { name: 'Response' })).toBeVisible();
    // The list is still there.
    await expect(app.row('/todos/1')).toBeVisible();
    await expect(app.field('Search URL or body')).toBeVisible();

    // Side by side: the panes share a band of the screen and do not overlap.
    const list = await app.row('/todos/1').boundingBox();
    const detail = await page.getByRole('tabpanel').boundingBox();
    if (list === null || detail === null) throw new Error('A pane has no box');
    expect(list.x + list.width).toBeLessThanOrEqual(detail.x);
    expect(list.x).toBeGreaterThanOrEqual(0);
    expect(detail.x + detail.width).toBeLessThanOrEqual(1280);
    expect(list.y).toBeLessThan(detail.y + detail.height);
    expect(detail.y).toBeLessThan(list.y + list.height);
  });

  test('390x844 shows the list, then the detail alone', async ({ app, page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await app.tap('GET JSON', todoResult);
    await app.openInspector();

    await expect(app.row('/todos/1')).toBeVisible();
    await expect(app.text('Select a request')).toBeHidden();
    await expect(page.getByRole('tab', { name: 'Response' })).toBeHidden();

    await app.row('/todos/1').click();
    await expect(page.getByRole('tab', { name: 'Response' })).toBeVisible();
    await expect(app.text('delectus aut autem')).toBeVisible();
    await expect(app.field('Search URL or body')).toBeHidden();

    await app.back();
    await expect(app.field('Search URL or body')).toBeVisible();
    await expect(page.getByRole('tab', { name: 'Response' })).toBeHidden();
  });

  test('resizing keeps the selected call', async ({ app, page }) => {
    await app.tap('GET JSON', todoResult);
    await app.openInspector();
    await app.row('/todos/1').click();
    await expect(app.text('delectus aut autem')).toBeVisible();

    await page.setViewportSize({ width: 390, height: 844 });
    await expect(app.field('Search URL or body')).toBeHidden();
    await expect(app.text('delectus aut autem')).toBeVisible();

    await page.setViewportSize({ width: 1280, height: 800 });
    await expect(app.field('Search URL or body')).toBeVisible();
    await expect(app.text('delectus aut autem')).toBeVisible();
  });
});

test.describe('Map Local', () => {
  test('a 404 rule from a call answers the next tap', async ({ app, net }) => {
    await app.tap('GET JSON', todoResult);
    await app.openInspector();
    await app.row('/todos/1').click();
    await app.map404FromOpenCall();
    await app.closeInspector();

    await app.tap('GET JSON', /^404 \(\d+ bytes\)$/);
    // Answered locally: the server saw only the first tap.
    expect(net.hits(todoUrl)).toBe(1);

    await app.openInspector();
    await expect(app.row('/todos/1', 'MAP', '404')).toBeVisible();
    await expect(app.row('/todos/1', '200')).toBeVisible();
  });

  test('the rules screen switches a rule off and on, and deletes it', async ({ app, net, page }) => {
    await app.tap('GET JSON', todoResult);
    await app.openInspector();
    await app.row('/todos/1').click();
    await app.map404FromOpenCall();

    await app.button('Rules').click();
    const toggle = (checked?: boolean) => page.getByRole('switch', { name: /GET \/todos\/1/, checked });
    await expect(toggle(true)).toBeVisible();

    // Off: the request reaches the server.
    await toggle().click();
    await expect(toggle(false)).toBeVisible();
    await app.back();
    await app.closeInspector();
    await app.tap('GET JSON', todoResult);
    expect(net.hits(todoUrl)).toBe(2);

    // On: answered by the rule again.
    await app.openInspector();
    await app.button('Rules').click();
    await toggle().click();
    await expect(toggle(true)).toBeVisible();
    await app.back();
    await app.closeInspector();
    await app.tap('GET JSON', /^404 \(\d+ bytes\)$/);
    expect(net.hits(todoUrl)).toBe(2);

    // Delete, Undo, delete: gone.
    await app.openInspector();
    await app.button('Rules').click();
    await app.button('Delete rule').click();
    await expect(app.text('No rules yet')).toBeVisible();
    await page.getByRole('button', { name: 'Undo' }).click();
    await expect(toggle(true)).toBeVisible();
    await app.button('Delete rule').click();
    await expect(app.text('No rules yet')).toBeVisible();
    await app.back();
    await app.closeInspector();
    await app.tap('GET JSON', todoResult);
    expect(net.hits(todoUrl)).toBe(3);
  });
});

test.describe('Edit & resend', () => {
  test('an edited resend reaches the server and is tagged', async ({ app, net, page }) => {
    await app.tap('GET JSON', todoResult);
    await app.openInspector();
    await app.row('/todos/1').click();
    await app.button('Edit & resend').click();
    await expect(page.getByRole('button', { name: 'Send' })).toBeVisible();

    await app.type(app.field('URL'), 'https://jsonplaceholder.typicode.com/todos/2');
    await page.getByRole('button', { name: 'Send' }).click();
    await expect(app.text(/· 200$/)).toBeVisible();
    expect(net.hits('https://jsonplaceholder.typicode.com/todos/2')).toBe(1);

    await page.getByRole('button', { name: 'Open call' }).click();
    await expect(app.row('/todos/2', 'REPLAY', 'EDITED', '200')).toBeVisible();
    await expect(app.text('id: 2')).toBeVisible();
    // The original row stays as it was.
    await expect(app.row('/todos/1', '200')).toBeVisible();
    await expect(app.row('/todos/1', 'REPLAY')).toBeHidden();
  });

  test('an unchanged resend is tagged REPLAY only', async ({ app, net, page }) => {
    await app.tap('GET JSON', todoResult);
    await app.openInspector();
    await app.row('/todos/1').click();
    await app.button('Edit & resend').click();
    await page.getByRole('button', { name: 'Send' }).click();
    await expect(app.text(/· 200$/)).toBeVisible();
    expect(net.hits(todoUrl)).toBe(2);
    await app.back();

    await expect(app.row('/todos/1', 'REPLAY', '200')).toBeVisible();
    await expect(app.row('/todos/1', 'EDITED')).toBeHidden();
  });
});

test.describe('breakpoint', () => {
  /** A breakpoint on the todo URL at `phase`; leaves the inspector closed. */
  async function addBreakpoint(app: App, page: Page, phase = 'Request'): Promise<void> {
    await app.tap('GET JSON', todoResult);
    await app.openInspector();
    await app.row('/todos/1').click();
    await app.button('Breakpoint on this URL').click();
    await expect(app.text('New rule')).toBeVisible();
    await page.getByRole('button', { name: phase, exact: true }).click();
    await app.button('Save rule').click();
    await expect(app.text('New rule')).toBeHidden();
    await app.closeInspector();
  }

  test('a pause opens the editor; Execute sends the edited header', async ({ app, net, page }) => {
    await addBreakpoint(app, page);

    await app.demoButton('GET JSON').click();
    app.noteCall();
    await expect(app.text('Request breakpoint')).toBeVisible();
    await expect(app.text('1 of 1 paused')).toBeVisible();
    expect(net.hits(todoUrl)).toBe(1);

    await page.getByRole('button', { name: /^Headers \(/ }).click();
    await app.button('Add header').click();
    await app.type(page.getByRole('textbox', { name: 'Name' }).last(), 'x-e2e');
    await app.type(page.getByRole('textbox', { name: 'Value' }).last(), 'edited');
    await page.getByRole('button', { name: 'Execute' }).click();

    // The inspector opened for the pause, so it closes with it.
    await expect(app.bubble).toBeVisible();
    await expect(app.text(todoResult)).toBeVisible();
    await expect.poll(() => net.hits(todoUrl)).toBe(2);
    expect(net.received.at(-1)!.headers()['x-e2e']).toBe('edited');

    await app.openInspector();
    await expect(app.row('/todos/1', 'BREAK', 'EDITED', '200')).toBeVisible();
  });

  test('Abort fails the call without sending it', async ({ app, net, page }) => {
    await addBreakpoint(app, page);

    await app.demoButton('GET JSON').click();
    app.noteCall();
    await expect(app.text('Request breakpoint')).toBeVisible();
    await page.getByRole('button', { name: 'Abort' }).click();

    await expect(app.bubble).toBeVisible();
    await expect(app.text(/^Failed:/)).toBeVisible();
    expect(net.hits(todoUrl)).toBe(1);

    await app.openInspector();
    await expect(app.row('/todos/1', 'BREAK', 'ERR')).toBeVisible();
  });

  test('a response breakpoint hands the app the edited status', async ({ app, net, page }) => {
    await addBreakpoint(app, page, 'Response');

    await app.demoButton('GET JSON').click();
    app.noteCall();
    await expect(app.text('Response breakpoint')).toBeVisible();
    // Paused after the send.
    expect(net.hits(todoUrl)).toBe(2);

    await app.type(app.field('Status'), '418');
    await page.getByRole('button', { name: 'Execute' }).click();

    await expect(app.bubble).toBeVisible();
    await expect(app.text(/^418 \(/)).toBeVisible();
    await app.openInspector();
    await expect(app.row('/todos/1', 'BREAK', 'EDITED', '418')).toBeVisible();
  });

  test('Continue unchanged sends the request as it was', async ({ app, net, page }) => {
    await addBreakpoint(app, page);

    await app.demoButton('GET JSON').click();
    app.noteCall();
    await page.getByRole('button', { name: 'Continue unchanged' }).click();

    await expect(app.bubble).toBeVisible();
    await expect.poll(() => net.hits(todoUrl)).toBe(2);
    await expect(app.text(todoResult)).toBeVisible();
    expect(net.received.at(-1)!.headers()['x-e2e']).toBeUndefined();

    await app.openInspector();
    await expect(app.row('/todos/1', 'BREAK', '200')).toBeVisible();
    await expect(app.row('/todos/1', 'EDITED')).toBeHidden();
  });
});
