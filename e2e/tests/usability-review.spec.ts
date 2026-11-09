import { expect, Locator, Page, test } from '@playwright/test';

test.use({ actionTimeout: 20_000 });

async function snapshot(page: Page) {
  return JSON.parse(await page.evaluate(() => (window as any).lifenizerE2eSnapshot()));
}

async function fill(page: Page, name: RegExp, value: string) {
  const field = page.getByRole('textbox', { name });
  await field.click();
  await field.press('ControlOrMeta+A');
  await field.pressSequentially(value);
  await field.press('Tab');
  await expect(field).toHaveValue(value);
}

// Enters the whole value as one input event, like a paste or dictation. On the
// 390px page this restarts the caret's scroll-into-view animation before it
// ever ticks, so the page is still scrolling when the next action starts.
async function paste(page: Page, name: RegExp, value: string) {
  const field = page.getByRole('textbox', { name });
  await field.click();
  await field.press('ControlOrMeta+A');
  await page.keyboard.insertText(value);
  await field.press('Tab');
  await expect(field).toHaveValue(value);
}

// While a Flutter Scrollable animates it ignores pointers, and the web engine
// drops flt-tappable from every button inside it. Playwright still sees those
// buttons as enabled and stable, so a click in that window is silently lost.
async function tap(button: Locator) {
  await expect(button).toHaveAttribute('flt-tappable', '');
  await button.click();
}

for (const width of [390, 1280]) {
  test(`capture drafts, final notes and streamed files recover at ${width}px`, async ({ page }, info) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.emulateMedia({ colorScheme: width === 390 ? 'dark' : 'light' });
    await page.goto('/');
    await page.waitForFunction(() => typeof (window as any).lifenizerE2eLogin === 'function');
    await page.evaluate(email => (window as any).lifenizerE2eLogin(email, 'http://127.0.0.1:5076'), `usability-${width}@example.test`);
    await expect.poll(async () => {
      const data = await snapshot(page);
      return data.authenticated && !data.busy;
    }).toBeTruthy();
    const capture = page.getByRole('tab', { name: 'Capture', exact: true })
      .or(page.getByRole('button', { name: /^Capture\b/ }));
    await capture.click();
    await fill(page, /^Text$/, 'Keep this unsaved capture across navigation.');

    await page.getByRole('button', { name: 'Lock vault', exact: true }).click();
    await expect(page.getByText('Discard drafts and lock?', { exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Keep editing', exact: true }).click();
    await page.getByRole('button', { name: /Find a conversation/ }).click();
    await capture.click();
    await page.getByRole('textbox', { name: /^Text$/ }).click();
    await expect(page.getByRole('textbox', { name: /^Text$/ })).toHaveValue('Keep this unsaved capture across navigation.');
    await tap(page.getByRole('button', { name: 'Encrypt import', exact: true }));
    await expect.poll(async () => (await snapshot(page)).conversations.length).toBe(1);
    expect((await snapshot(page)).conversations[0].segments[0].text).toBe('Keep this unsaved capture across navigation.');
    await page.getByRole('textbox', { name: /^Text$/ }).click();
    await expect(page.getByRole('textbox', { name: /^Text$/ })).toHaveValue('');

    await tap(page.getByRole('button', { name: 'Start session', exact: true }));
    await paste(page, /^Typed segment$/, 'The final note needs no extra Add segment click.');
    await tap(page.getByRole('button', { name: 'Stop session', exact: true }));
    await expect.poll(async () => {
      const data = await snapshot(page);
      return data.conversations.find((item: any) => item.source === 'live-recording')?.segments.map((item: any) => item.text);
    }).toEqual(['The final note needs no extra Add segment click.']);

    const chooser = page.waitForEvent('filechooser');
    await tap(page.getByRole('button', { name: 'Choose file', exact: true }));
    await (await chooser).setFiles({
      name: 'watch-history.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify([{
        header: 'YouTube', title: 'Watched Usability review video',
        titleUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        time: '2026-10-01T10:00:00Z', products: ['YouTube'],
      }])),
    });
    await expect.poll(async () => (await snapshot(page)).conversations.length).toBe(3);
    expect((await snapshot(page)).conversations.some((item: any) => item.source === 'youtube-watch-history')).toBeTruthy();
    expect((await snapshot(page)).error).toBeFalsy();
    await page.screenshot({ path: info.outputPath(`capture-${width}.png`), fullPage: true });
    await page.getByRole('button', { name: /Find a conversation/ }).click();
    await expect(page.getByRole('textbox', { name: /Search text, people, relations/ })).toBeVisible();
    await page.screenshot({ path: info.outputPath(`search-${width}.png`), fullPage: true });
  });
}
