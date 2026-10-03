import { expect, Page, test } from '@playwright/test';

async function snapshot(page: Page) {
  return JSON.parse(await page.evaluate(() => (window as any).lifenizerE2eSnapshot()));
}
async function settled(page: Page, predicate: (data: any) => boolean) {
  await expect.poll(async () => {
    const data = await snapshot(page);
    if (data.error) throw new Error(data.error);
    return !data.busy && predicate(data);
  }, { timeout: 60_000 }).toBeTruthy();
}

async function fillField(page: Page, name: RegExp, value: string) {
  const field = page.getByRole('textbox', { name });
  await field.click();
  await field.fill(value);
  await field.press('Tab');
  await expect(field).toHaveValue(value);
}

test('account UI, search quick action, offline unlock and queued capture survive reload', async ({ page, context }) => {
  test.setTimeout(180_000);
  await page.goto('/?action=search&q=Person%20X');
  await page.waitForFunction(() => typeof (window as any).lifenizerE2eSnapshot === 'function');
  await page.getByRole('button', { name: 'Create an account', exact: true }).click();
  await fillField(page, /^API URL/, 'http://127.0.0.1:5076');
  await fillField(page, /^Email/, 'offline-ui@example.test');
  await fillField(page, /^Account password/, 'account password for e2e');
  await fillField(page, /^Vault passphrase/, 'correct horse battery staple');
  await fillField(page, /^Repeat vault passphrase/, 'correct horse battery staple');
  await page.getByRole('button', { name: 'Create encrypted vault', exact: true }).click();
  await settled(page, data => data.authenticated);
  await expect(page.getByRole('textbox', { name: /Search text, people, relations/ })).toHaveValue('Person X');
  await page.evaluate(() => (window as any).lifenizerE2eImportText());
  await settled(page, data => data.conversations.length === 1 && data.pendingSync === 0);

  // Reload reopens IndexedDB and drops all in-memory decrypted state.
  await page.reload();
  await page.waitForFunction(() => typeof (window as any).lifenizerE2eSnapshot === 'function');
  await context.setOffline(true);
  await fillField(page, /^Vault passphrase/, 'correct horse battery staple');
  await page.getByRole('button', { name: 'Unlock this device offline', exact: true }).click();
  await settled(page, data => data.authenticated && data.conversations.length === 1);
  await page.evaluate(() => (window as any).lifenizerE2eImportText());
  await settled(page, data => data.conversations.length === 2 && data.pendingSync > 0);
  await context.setOffline(false);
  await page.evaluate(() => (window as any).lifenizerE2ePull());
  await settled(page, data => data.pendingSync === 0);
  await page.getByRole('button', { name: 'Lock vault', exact: true }).click();
  await settled(page, data => !data.authenticated && data.conversations.length === 0);
});
