import * as path from 'node:path';
import { expect, test as base, type Locator, type Page, type Request, type Route } from '@playwright/test';

const buildDir = path.join(__dirname, '..', '..', 'example', 'build', 'web');

const cors = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': '*',
  'access-control-allow-methods': '*',
};

const jsonHeaders = { ...cors, 'content-type': 'application/json' };

// A 1x1 PNG.
export const png = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEAQH/7yMK/gAAAABJRU5ErkJggg==',
  'base64',
);

export const todo = JSON.stringify({ userId: 1, id: 1, title: 'delectus aut autem', completed: false });
export const created = JSON.stringify({ id: 101, title: 'Proxie', body: 'demo', userId: 1 });
export const user = JSON.stringify({ id: 1, name: 'Leanne Graham', username: 'Bret' });

type Fixed = { status: number; headers: Record<string, string>; body: string | Buffer };

/** The fixed answers of the hosts the demo buttons call, by `METHOD url`. */
const answers: Record<string, Fixed> = {
  'GET https://jsonplaceholder.typicode.com/todos/1': { status: 200, headers: jsonHeaders, body: todo },
  'GET https://jsonplaceholder.typicode.com/todos/2': { status: 200, headers: jsonHeaders, body: '{"id":2}' },
  'POST https://jsonplaceholder.typicode.com/posts': { status: 201, headers: jsonHeaders, body: created },
  'GET https://jsonplaceholder.typicode.com/users/1': { status: 200, headers: jsonHeaders, body: user },
  'GET https://httpbin.org/status/404': { status: 404, headers: cors, body: '' },
  'GET https://httpbin.org/status/500': { status: 500, headers: cors, body: '' },
  'GET https://httpbin.org/image/png': { status: 200, headers: { ...cors, 'content-type': 'image/png' }, body: png },
};

/**
 * Answers every request that would leave the machine, so the suite runs
 * offline: the demo's hosts get fixed responses, Flutter's CanvasKit comes
 * from the local build, and web fonts are refused (text then uses a fallback
 * font, which the tests do not depend on). Anything else is refused and fails
 * the test.
 */
export class Network {
  /** Requests the demo's hosts received, in order. */
  readonly received: Request[] = [];
  /** Requests nothing here expected. */
  readonly unexpected: string[] = [];

  async install(page: Page): Promise<void> {
    await page.route(
      (url) => url.hostname !== 'localhost',
      (route) => this.answer(route),
    );
  }

  private async answer(route: Route): Promise<void> {
    const request = route.request();
    const url = new URL(request.url());
    if (url.hostname === 'www.gstatic.com' && url.pathname.includes('/flutter-canvaskit/')) {
      const file = url.pathname.split('/').slice(3).join('/');
      await route.fulfill({ path: path.join(buildDir, 'canvaskit', file), headers: cors });
      return;
    }
    if (url.hostname === 'fonts.gstatic.com') {
      await route.abort();
      return;
    }
    const answer = answers[`${request.method()} ${request.url()}`];
    if (answer === undefined) {
      this.unexpected.push(`${request.method()} ${request.url()}`);
      await route.abort();
      return;
    }
    this.received.push(request);
    await route.fulfill(answer);
  }

  /** How many requests to `url` arrived. */
  hits(url: string): number {
    return this.received.filter((r) => r.url() === url).length;
  }
}

export const todoUrl = 'https://jsonplaceholder.typicode.com/todos/1';

/** The example app, driven through its accessibility tree. */
export class App {
  private calls = 0;

  constructor(readonly page: Page) {}

  async open(): Promise<void> {
    await this.page.goto('/');
    await expect(this.demoButton('GET JSON')).toBeVisible({ timeout: 60_000 });
    await expect(this.bubble).toBeVisible({ timeout: 30_000 });
  }

  /** Text on screen. Announcements for screen readers live elsewhere. */
  text(text: string | RegExp): Locator {
    return this.page.locator('flt-semantics-host').getByText(text);
  }

  /** The floating button; its name carries the call count. */
  get bubble(): Locator {
    return this.page.getByRole('button', { name: /^Open Proxie inspector/ });
  }

  demoButton(label: string): Locator {
    return this.page.getByRole('button', { name: label, exact: true });
  }

  /**
   * Taps a demo button with the inspector closed and waits for the call to be
   * seen (the old result is gone by then, so a repeat of the same result
   * cannot satisfy `expected` early).
   */
  async tap(label: string, expected?: string | RegExp): Promise<void> {
    await this.demoButton(label).click();
    this.calls++;
    await expect(this.bubble).toHaveAccessibleName(
      `Open Proxie inspector ${this.calls} ${this.calls === 1 ? 'call' : 'calls'}`,
      { timeout: 30_000 },
    );
    if (expected !== undefined) {
      await expect(this.text(expected)).toBeVisible();
    }
  }

  /** Counts a call made another way than [tap]. */
  noteCall(): void {
    this.calls++;
  }

  async openInspector(): Promise<void> {
    await this.bubble.click();
    await expect(this.page.getByRole('heading', { name: 'Proxie', exact: true })).toBeVisible();
  }

  async closeInspector(): Promise<void> {
    await this.button('Close').click();
    await expect(this.bubble).toBeVisible();
  }

  /** The list row of a call, by what its accessible name holds, in order. */
  row(...parts: (string | RegExp)[]): Locator {
    const source = parts
      .map((p) => (typeof p === 'string' ? p.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&') : p.source))
      .join('.*');
    return this.page.getByRole('button', { name: new RegExp(source) });
  }

  /** A button by its name. A hovered tooltip repeats its text in the name. */
  button(name: string): Locator {
    return this.page.getByRole('button', { name, exact: false });
  }

  field(name: string): Locator {
    return this.page.getByRole('textbox', { name, exact: true });
  }

  /** Replaces what `field` holds, typing like a user. */
  async type(field: Locator, text: string): Promise<void> {
    await field.click();
    await field.press('Control+a');
    await this.page.keyboard.type(text);
    await expect(field).toHaveValue(text);
  }

  async back(): Promise<void> {
    await this.button('Back').click();
  }

  /** Makes a Map Local rule answering 404 from the call open in the detail. */
  async map404FromOpenCall(): Promise<void> {
    await this.button('Map Local from this response').click();
    await expect(this.text('New rule')).toBeVisible();
    await this.page.getByRole('tab', { name: 'Response' }).click();
    await this.button('Presets').click();
    await this.page.getByRole('button', { name: '404 Not Found' }).click();
    await this.button('Save rule').click();
    await expect(this.text('New rule')).toBeHidden();
  }
}

/** Dart errors reach the browser console in these forms. */
const dartError = /EXCEPTION CAUGHT BY|Another exception was thrown|Uncaught|Unhandled/;

export const test = base.extend<{ net: Network; app: App }>({
  net: async ({ page }, use) => {
    const net = new Network();
    await net.install(page);
    await use(net);
    expect(net.unexpected, 'requests that would leave the machine').toEqual([]);
  },
  app: async ({ page, net }, use) => {
    void net;
    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => {
      if (dartError.test(m.text())) errors.push(m.text());
    });
    const app = new App(page);
    await app.open();
    await use(app);
    expect(errors, 'errors in the browser console').toEqual([]);
  },
});

export { expect };
