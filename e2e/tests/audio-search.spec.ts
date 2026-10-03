import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, Page, test } from '@playwright/test';

const apiUrl = 'http://127.0.0.1:5075';
const whisperUrl = process.env.WHISPER_URL ?? 'http://127.0.0.1:19000';
const audioPath = process.env.E2E_AUDIO_FILE ?? 'fixtures/speech-sample.wav';
const expectedKeyword = (process.env.E2E_AUDIO_KEYWORD ?? 'country').toLowerCase();
const speaker = 'Person X';

type Hit = { title: string; source: string; startedAt?: string };

async function whisperReachable(): Promise<boolean> {
  try {
    const response = await fetch(`${whisperUrl}/docs`, { signal: AbortSignal.timeout(5_000) });
    return response.ok;
  } catch {
    return false;
  }
}

async function login(page: Page, email: string) {
  await page.goto('/');
  await page.waitForFunction(() => typeof (window as any).lifenizerE2eLogin === 'function');
  await page.evaluate(([nextEmail, nextApiUrl]) => {
    (window as any).lifenizerE2eLogin(nextEmail, nextApiUrl);
  }, [email, apiUrl]);
  await expect.poll(async () => (await snapshot(page)).authenticated, { timeout: 30_000 }).toBeTruthy();
}

async function snapshot(page: Page) {
  return JSON.parse(await page.evaluate(() => (window as any).lifenizerE2eSnapshot()));
}

async function search(page: Page, query: string, options: { participant?: string; from?: string; to?: string } = {}): Promise<Hit[]> {
  const raw = await page.evaluate(([q, participant, from, to]) => {
    return (window as any).lifenizerE2eSearch(q, participant, from, to);
  }, [query, options.participant ?? '', options.from ?? '', options.to ?? '']);
  return JSON.parse(raw) as Hit[];
}

async function importAudio(page: Page, audioBase64: string, title: string, recordedAt: string) {
  await page.evaluate(([payload, participant, nextRecordedAt, nextTitle]) => {
    (window as any).lifenizerE2eImportAudio(payload, 'voice-memo.wav', 'audio/wav', participant, nextRecordedAt, nextTitle);
  }, [audioBase64, speaker, recordedAt, title]);

  await expect.poll(async () => {
    const data = await snapshot(page);
    if (data.error) throw new Error(`Import failed: ${data.error}`);
    return data.conversations.some((conversation: Hit) => conversation.source === 'audio' && conversation.title === title);
  }, { timeout: 270_000, intervals: [2_000] }).toBeTruthy();
}

function isoDay(offsetDays: number): string {
  const date = new Date();
  date.setDate(date.getDate() + offsetDays);
  return date.toISOString().slice(0, 10);
}

test('audio recording is transcribed by whisper and found by keyword, person and time', async ({ browser, page }) => {
  test.skip(!(await whisperReachable()), `No whisper-asr-webservice reachable at ${whisperUrl}.`);
  test.setTimeout(600_000);

  const audioBase64 = readFileSync(resolve(audioPath)).toString('base64');
  await login(page, 'audio@example.test');

  const recentTitle = 'Voice memo from today';
  const oldTitle = 'Voice memo from last year';
  await importAudio(page, audioBase64, recentTitle, '');
  await importAudio(page, audioBase64, oldTitle, `${isoDay(-350)}T18:05:00Z`);

  const byKeyword = await search(page, expectedKeyword);
  expect(byKeyword.map(hit => hit.title)).toEqual(expect.arrayContaining([recentTitle, oldTitle]));
  expect(byKeyword.map(hit => hit.source)).toContain('audio');

  const byTypo = await search(page, `${expectedKeyword.slice(0, -1)}x`);
  expect(byTypo.map(hit => hit.source)).toContain('audio');

  const byPerson = await search(page, speaker.toLowerCase());
  expect(byPerson.map(hit => hit.source)).toContain('audio');

  // A recording is dated by when it was recorded, not by when it was imported.
  const today = await search(page, expectedKeyword, { from: isoDay(-1), to: isoDay(1) });
  expect(today.map(hit => hit.title)).toEqual([recentTitle]);

  const lastYear = await search(page, expectedKeyword, { from: isoDay(-400), to: isoDay(-300) });
  expect(lastYear.map(hit => hit.title)).toEqual([oldTitle]);

  const emptyPeriod = await search(page, expectedKeyword, { from: isoDay(-200), to: isoDay(-100) });
  expect(emptyPeriod).toEqual([]);

  const combined = await search(page, expectedKeyword, { participant: speaker, from: isoDay(-400), to: isoDay(-300) });
  expect(combined.map(hit => hit.title)).toEqual([oldTitle]);

  const unrelated = await search(page, 'zebra submarine');
  expect(unrelated.map(hit => hit.source)).not.toContain('audio');

  // The transcript must survive encrypted sync to a second device and stay searchable there.
  const secondContext = await browser.newContext();
  const secondDevice = await secondContext.newPage();
  await login(secondDevice, 'audio@example.test');
  await expect.poll(async () => (await search(secondDevice, expectedKeyword)).map(hit => hit.source), { timeout: 60_000 }).toContain('audio');
  await secondContext.close();
});
