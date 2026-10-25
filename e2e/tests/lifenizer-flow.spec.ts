import { expect, Page, test } from '@playwright/test';

const apiUrl = 'http://127.0.0.1:5076';
const passphrase = 'correct horse battery staple';

type Snapshot = {
  authenticated: boolean;
  busy: boolean;
  cursor: number;
  pendingSync: number;
  participants: Array<{ displayName: string }>;
  conversations: Array<{ title: string; source: string; tags?: string[] }>;
  relations: Array<{ subject: string; relation: string; object: string }>;
  savedSearches: Array<{ title: string; query: string; source?: string; tag?: string }>;
  tags: string[];
  insights: {
    totalConversations: number;
    totalSegments: number;
    sources: Array<{ source: string; count: number }>;
    participants: Array<{ displayName: string; count: number }>;
  };
  imports: string[];
  status?: string;
  error?: string;
};

async function login(page: Page, email: string) {
  await page.goto('/');
  await page.waitForFunction(() => typeof (window as any).lifenizerE2eLogin === 'function');
  await page.evaluate(([nextEmail, nextApiUrl]) => {
    (window as any).lifenizerE2eLogin(nextEmail, nextApiUrl);
  }, [email, apiUrl]);
  await waitForSnapshot(page, snapshot => snapshot.authenticated && snapshot.imports.includes('manual-text'));
}

async function runBridge(page: Page, name: string) {
  await page.evaluate((functionName) => {
    (window as any)[functionName]();
  }, name);
}

async function snapshot(page: Page): Promise<Snapshot> {
  return JSON.parse(await page.evaluate(() => (window as any).lifenizerE2eSnapshot())) as Snapshot;
}

async function waitForSnapshot(page: Page, predicate: (snapshot: Snapshot) => boolean) {
  await expect.poll(async () => {
    const data = await snapshot(page);
    if (data.error) throw new Error(data.error);
    return !data.busy && predicate(data);
  }, { timeout: 30_000 }).toBeTruthy();
}

test('encrypted sync, search, relations, and user isolation across browser contexts', async ({ browser, page }) => {
  await login(page, 'alice@example.test');

  await runBridge(page, 'lifenizerE2eImportText');
  await waitForSnapshot(page, data => data.conversations.some(conversation => conversation.title === 'Coffee with Person X'));

  await runBridge(page, 'lifenizerE2eRecording');
  await waitForSnapshot(page, data => data.conversations.some(conversation => conversation.source === 'live-recording'));

  await runBridge(page, 'lifenizerE2eImportBackend');
  await waitForSnapshot(page, data => data.conversations.some(conversation => conversation.source === 'whatsapp'));

  await runBridge(page, 'lifenizerE2eSaveSearch');
  await waitForSnapshot(page, data =>
    data.savedSearches.some(search => search.title === 'Person X WhatsApp' && search.source === 'whatsapp') &&
    data.tags.includes('whatsapp') &&
    data.insights.sources.some(source => source.source === 'whatsapp' && source.count >= 1)
  );

  await runBridge(page, 'lifenizerE2eExtractRelations');
  await waitForSnapshot(page, data => data.relations.some(relation =>
    relation.subject === 'Person X' && relation.relation === 'brother' && relation.object === 'Person Y'
  ));

  // Publish the first device's queued batch before opening a second device.
  await runBridge(page, 'lifenizerE2ePull');
  await waitForSnapshot(page, data => data.pendingSync === 0);

  const secondContext = await browser.newContext();
  const secondDevice = await secondContext.newPage();
  await login(secondDevice, 'alice@example.test');
  await waitForSnapshot(secondDevice, data =>
    data.conversations.some(conversation => conversation.title === 'Coffee with Person X') &&
    data.conversations.some(conversation => conversation.source === 'whatsapp') &&
    data.savedSearches.some(search => search.title === 'Person X WhatsApp') &&
    data.tags.includes('chat') &&
    data.insights.totalConversations >= 3 &&
    data.relations.some(relation => relation.relation === 'brother')
  );
  await secondContext.close();

  const otherUserContext = await browser.newContext();
  const otherUser = await otherUserContext.newPage();
  await login(otherUser, 'bob@example.test');
  await waitForSnapshot(otherUser, data => data.conversations.length === 0 && data.relations.length === 0);
  await otherUserContext.close();
});

test('API-served landing pages load', async ({ page }) => {
  await page.goto(apiUrl);
  await expect(page.getByRole('heading', { name: /Keep what matters/ })).toBeVisible();
  await page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'Security', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Your archive, on your terms.' })).toBeVisible();

  await page.route(`${apiUrl}/api/downloads`, route => route.fulfill({
    json: ['chromium', 'firefox'].map(browser => ({
      name: `lifenizer-history-sync-${browser}.zip`,
      available: true,
    })),
  }));
  await page.goto(`${apiUrl}/#extensions`);
  await expect(page).toHaveURL(`${apiUrl}/extension`);
  await expect(page.getByRole('heading', { name: 'Browser extension', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Chrome / Edge ZIP', exact: true })).toHaveAttribute('href', '/downloads/lifenizer-history-sync-chromium.zip');
  await expect(page.getByRole('link', { name: 'Firefox ZIP', exact: true })).toHaveAttribute('href', '/downloads/lifenizer-history-sync-firefox.zip');
  await expect(page.getByRole('heading', { name: '1. Install the extension' })).toBeVisible();
  await expect(page.getByText('Load unpacked', { exact: true })).toBeVisible();
  await expect(page.getByText('Load Temporary Add-on', { exact: true })).toBeVisible();
  await expect(page.getByText(/This temporary installation lasts until Firefox restarts/)).toBeVisible();
  await expect(page.getByRole('heading', { name: '2. Connect to Lifenizer' })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Connect installed extension', exact: true })).toHaveAttribute('href', 'lifenizer://connect-extension');
  await expect(page.locator('[data-download="lifenizer.apk"], [data-download="lifenizer-linux-x64.tar.gz"]')).toHaveCount(0);
});
