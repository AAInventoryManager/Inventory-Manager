import { test, expect } from '@playwright/test';

test('loads the app shell', async ({ page }) => {
  const url = process.env.SUPABASE_URL;
  const anon = process.env.SUPABASE_ANON_KEY;
  if (url && anon) {
    await page.addInitScript(({ url, anon }) => {
      window.SB_URL = url;
      window.SB_ANON = anon;
    }, { url, anon });
  }

  await page.goto('/');
  await expect(page.locator('#filterBox')).toBeVisible();
  await expect(page.locator('header')).toBeVisible();
});
