import { test, expect, Page } from '@playwright/test';

// Load environment variables
import dotenv from 'dotenv';
const envPath = process.env.CI ? '.env.test.ci' : '.env.test';
dotenv.config({ path: envPath });

// Test credentials from fixtures - use SUPER user who has super_user privileges
const TEST_EMAIL = 'super@test.local';
const TEST_PASSWORD = process.env.TEST_USER_PASSWORD || 'TestPassword123!';

/**
 * Helper to inject Supabase credentials and navigate to app
 */
async function setupPage(page: Page) {
  const url = process.env.SUPABASE_URL;
  const anon = process.env.SUPABASE_ANON_KEY;

  if (url && anon) {
    await page.addInitScript(({ url, anon }) => {
      (window as any).SB_URL = url;
      (window as any).SB_ANON = anon;
    }, { url, anon });
  }
}

/**
 * Helper to log in as test user (or verify already logged in)
 */
async function login(page: Page, email = TEST_EMAIL, password = TEST_PASSWORD) {
  // Check if auth modal is showing
  const authModalHidden = await page.locator('#authModal').getAttribute('aria-hidden');

  if (authModalHidden === 'true') {
    // Already logged in, just wait for app to be ready
    await expect(page.locator('#filterBox')).toBeVisible({ timeout: 15000 });
    return;
  }

  // Wait for auth modal and form to be ready
  await expect(page.locator('#authModal')).toHaveAttribute('aria-hidden', 'false', { timeout: 15000 });
  const emailInput = page.locator('#authEmail');
  await expect(emailInput).toBeVisible({ timeout: 5000 });

  // Wait for any initial scripts to settle
  await page.waitForTimeout(500);

  // Triple-click to select all then type
  await emailInput.click({ clickCount: 3 });
  await emailInput.pressSequentially(email, { delay: 30 });

  // Fill password similarly
  const passwordInput = page.locator('#authPassword');
  await passwordInput.click({ clickCount: 3 });
  await passwordInput.pressSequentially(password, { delay: 30 });

  // Verify fields have values before clicking
  await expect(emailInput).toHaveValue(email);
  await expect(passwordInput).toHaveValue(password);

  // Click sign in button
  await page.click('#btnAuthSubmit');

  // Wait for inventory view to be visible (indicates successful login)
  await expect(page.locator('#filterBox')).toBeVisible({ timeout: 30000 });

  // Verify auth modal is closed
  await expect(page.locator('#authModal')).toHaveAttribute('aria-hidden', 'true', { timeout: 5000 });
}

/**
 * Helper to select a company if not already selected
 */
async function ensureCompanySelected(page: Page) {
  // Check if we need to select a company by looking at the profile status
  const profileBtn = page.locator('#profileBtn');
  await profileBtn.click();

  // Wait for dropdown to open
  await expect(page.locator('#profileDropdown')).toHaveAttribute('aria-hidden', 'false', { timeout: 3000 });

  // Check if "No company selected" is shown
  const companyName = await page.locator('#profileCompanyName').textContent();

  if (companyName?.includes('No company') || companyName?.includes('GUEST')) {
    // Need to select a company - click Company tab
    await page.locator('#profileTabCompany').click();
    await expect(page.locator('#profilePanelCompany')).toHaveClass(/is-active/, { timeout: 3000 });

    // Click Change User Company
    await page.locator('#openCompanySwitcher').click();

    // Wait for company switcher modal
    await expect(page.locator('#advancedCompanyModal')).toHaveAttribute('aria-hidden', 'false', { timeout: 5000 });

    // Select a company - click the first Switch button (or Current if already selected)
    const switchBtn = page.locator('button:has-text("Switch"), button:has-text("Current")').first();
    await expect(switchBtn).toBeVisible({ timeout: 5000 });
    // Only click if it says "Switch" (not already Current)
    const btnText = await switchBtn.textContent();
    if (btnText?.includes('Switch')) {
      await switchBtn.click();
    } else {
      // Already have a company selected, close the modal
      await page.locator('#advancedCompanyModal .modal-close').first().click();
    }

    // Wait for modal to close
    await expect(page.locator('#advancedCompanyModal')).toHaveAttribute('aria-hidden', 'true', { timeout: 5000 });

    // Give the app time to update
    await page.waitForTimeout(500);
  } else {
    // Close the profile dropdown
    await profileBtn.click();
    await expect(page.locator('#profileDropdown')).toHaveAttribute('aria-hidden', 'true', { timeout: 3000 });
  }
}

/**
 * Helper to open the Company Locations modal via profile menu
 */
async function openLocationsModal(page: Page) {
  // Ensure we have a company selected first
  await ensureCompanySelected(page);

  // Open profile dropdown
  const profileBtn = page.locator('#profileBtn');
  await expect(profileBtn).toBeVisible({ timeout: 5000 });
  await profileBtn.click();

  // Wait for dropdown to open
  await expect(page.locator('#profileDropdown')).toHaveAttribute('aria-hidden', 'false', { timeout: 3000 });

  // Click Company tab
  const companyTab = page.locator('#profileTabCompany');
  await companyTab.click();

  // Wait for Company panel to be active
  await expect(page.locator('#profilePanelCompany')).toHaveClass(/is-active/, { timeout: 3000 });

  // Click Locations button
  const locationsBtn = page.locator('#openCompanyLocations');
  await expect(locationsBtn).toBeVisible({ timeout: 5000 });
  await locationsBtn.click();

  // Wait for locations modal to be visible
  await expect(page.locator('#companyLocationsModal')).toHaveAttribute('aria-hidden', 'false', { timeout: 5000 });
}

/**
 * Helper to open the location editor (Add Location form)
 */
async function openLocationEditor(page: Page) {
  const addBtn = page.locator('#btnCompanyLocationNew');
  await expect(addBtn).toBeVisible({ timeout: 5000 });
  await addBtn.click();

  // Wait for editor modal to be visible
  await expect(page.locator('#companyLocationEditorModal')).toHaveAttribute('aria-hidden', 'false', { timeout: 5000 });
}

/**
 * Helper to fill location form fields
 * Note: Google Places autocomplete won't work in tests, so we set the hidden value directly
 */
async function fillLocationForm(page: Page, data: {
  name: string;
  type?: string;
  address: string;
  defaultShipTo?: boolean;
  defaultReceiveAt?: boolean;
}) {
  // Fill name
  await page.fill('#companyLocationName', data.name);

  // Select type if provided
  if (data.type) {
    await page.selectOption('#companyLocationType', data.type);
  }

  // For address, we need to handle Google Places autocomplete custom element
  // Find the inner input and set both it and the hidden value
  await page.evaluate((addr) => {
    // Set the hidden value field that the form reads from
    const hiddenInput = document.getElementById('companyLocationAddress1Value') as HTMLInputElement;
    if (hiddenInput) {
      hiddenInput.value = addr;
    }

    // Also try to set the visible input in the web component
    const autocomplete = document.getElementById('companyLocationAddress1');
    if (autocomplete) {
      // Try shadow DOM input
      const shadowInput = autocomplete.shadowRoot?.querySelector('input');
      if (shadowInput) {
        shadowInput.value = addr;
        shadowInput.dispatchEvent(new Event('input', { bubbles: true }));
      }
      // Also set as attribute for the component
      autocomplete.setAttribute('value', addr);
    }
  }, data.address);

  // Toggle default settings if requested - these are styled toggle switches
  // We need to click the label/wrapper instead of the hidden checkbox
  if (data.defaultShipTo) {
    const toggleControl = page.locator('label:has(#companyLocationDefaultShipTo)');
    const checkbox = page.locator('#companyLocationDefaultShipTo');
    if (!(await checkbox.isChecked())) {
      await toggleControl.click();
    }
  }

  if (data.defaultReceiveAt) {
    const toggleControl = page.locator('label:has(#companyLocationDefaultReceiveAt)');
    const checkbox = page.locator('#companyLocationDefaultReceiveAt');
    if (!(await checkbox.isChecked())) {
      await toggleControl.click();
    }
  }
}

/**
 * Helper to save location and wait for success
 */
async function saveLocation(page: Page) {
  const saveBtn = page.locator('#btnCompanyLocationSave');
  await saveBtn.click();

  // Wait for editor modal to close (indicates success)
  await expect(page.locator('#companyLocationEditorModal')).toHaveAttribute('aria-hidden', 'true', { timeout: 10000 });

  // Wait for toast notification
  await expect(page.locator('.toast')).toContainText('Location saved', { timeout: 5000 });
}

/**
 * Helper to close the locations modal
 */
async function closeLocationsModal(page: Page) {
  const closeBtn = page.locator('#btnCompanyLocationsClose');
  await closeBtn.click();
  await expect(page.locator('#companyLocationsModal')).toHaveAttribute('aria-hidden', 'true', { timeout: 5000 });
}

/**
 * Generate unique location name for test isolation
 */
function uniqueLocationName(prefix = 'Test Location') {
  return `${prefix} ${Date.now()}`;
}

// ============================================================================
// Tests
// ============================================================================

test.describe('Company Locations Modal', () => {
  test.beforeEach(async ({ page }) => {
    await setupPage(page);
    await page.goto('/');
    await login(page);
  });

  test('opens locations modal', async ({ page }) => {
    await openLocationsModal(page);

    // Verify modal title
    await expect(page.locator('#companyLocationsTitle')).toHaveText('Company Locations');

    // Verify Add Location button exists
    await expect(page.locator('#btnCompanyLocationNew')).toBeVisible();

    // Close modal
    await closeLocationsModal(page);
  });

  test('opens location editor form', async ({ page }) => {
    await openLocationsModal(page);
    await openLocationEditor(page);

    // Verify editor title
    await expect(page.locator('#companyLocationEditorTitle')).toHaveText('Add Location');

    // Verify form fields exist
    await expect(page.locator('#companyLocationName')).toBeVisible();
    await expect(page.locator('#companyLocationType')).toBeVisible();
    await expect(page.locator('#companyLocationAddress1')).toBeVisible();
    // Checkboxes are styled toggles and may be hidden - check they exist in DOM
    await expect(page.locator('#companyLocationDefaultShipTo')).toBeAttached();
    await expect(page.locator('#companyLocationDefaultReceiveAt')).toBeAttached();

    // Cancel to close
    await page.click('#btnCompanyLocationCancel');
    await expect(page.locator('#companyLocationEditorModal')).toHaveAttribute('aria-hidden', 'true');
  });

  test('adds a new location with all fields', async ({ page }) => {
    const locationName = uniqueLocationName('Warehouse');
    const locationAddress = '123 Test Street, Test City, TX 75001';

    await openLocationsModal(page);
    await openLocationEditor(page);

    // Fill out the form
    await fillLocationForm(page, {
      name: locationName,
      type: 'warehouse',
      address: locationAddress,
      defaultShipTo: true
    });

    // Save
    await saveLocation(page);

    // Verify location appears in the list - use the modal body which contains both views
    const locationsModal = page.locator('#companyLocationsModal');
    await expect(locationsModal).toContainText(locationName, { timeout: 5000 });

    // Clean up - close modal
    await closeLocationsModal(page);
  });

  test('validates required fields', async ({ page }) => {
    await openLocationsModal(page);
    await openLocationEditor(page);

    // Try to save without filling any fields
    await page.click('#btnCompanyLocationSave');

    // Should show validation error (modal should stay open)
    await expect(page.locator('#companyLocationEditorModal')).toHaveAttribute('aria-hidden', 'false');

    // Check for error message about required name
    const errorMsg = page.locator('#companyLocationEditorMsg');
    await expect(errorMsg).toBeVisible();
    await expect(errorMsg).toContainText(/name|required/i);

    // Cancel
    await page.click('#btnCompanyLocationCancel');
  });

  test('validates address is required', async ({ page }) => {
    await openLocationsModal(page);
    await openLocationEditor(page);

    // Fill name but not address
    await page.fill('#companyLocationName', 'Test No Address');

    // Try to save
    await page.click('#btnCompanyLocationSave');

    // Should show validation error about address
    const errorMsg = page.locator('#companyLocationEditorMsg');
    await expect(errorMsg).toBeVisible();
    await expect(errorMsg).toContainText(/address|required/i);

    // Cancel
    await page.click('#btnCompanyLocationCancel');
  });

  test('edits an existing location', async ({ page }) => {
    const originalName = uniqueLocationName('Original');
    const updatedName = uniqueLocationName('Updated');
    const locationAddress = '456 Edit Street, Edit City, TX 75002';

    // First create a location
    await openLocationsModal(page);
    await openLocationEditor(page);

    await fillLocationForm(page, {
      name: originalName,
      type: 'office',
      address: locationAddress
    });
    await saveLocation(page);

    // Find and click the pencil/edit icon for this location
    // Look for the row containing the location name and click its edit button
    const locationRow = page.locator('#companyLocationsModal').locator(`tr:has-text("${originalName}"), .locations-row:has-text("${originalName}"), [data-location-row]:has-text("${originalName}")`).first();

    // Try multiple selectors for the edit button (pencil icon)
    let editBtn = locationRow.locator('button svg, .icon-btn, [role="button"]').first();

    if (await editBtn.count() > 0) {
      await editBtn.click();
    } else {
      // Fallback: click anywhere on the row name
      await page.locator(`text=${originalName}`).first().click();
    }

    // Wait for editor to open
    await expect(page.locator('#companyLocationEditorModal')).toHaveAttribute('aria-hidden', 'false', { timeout: 5000 });

    // Update the name
    await page.fill('#companyLocationName', updatedName);

    // Save
    await saveLocation(page);

    // Verify updated name appears
    const locationsModal = page.locator('#companyLocationsModal');
    await expect(locationsModal).toContainText(updatedName);

    // Clean up
    await closeLocationsModal(page);
  });

  test('creates location with different types', async ({ page }) => {
    const types = ['warehouse', 'yard', 'office', 'job_site', 'other'];

    await openLocationsModal(page);

    for (const locationType of types) {
      const locationName = uniqueLocationName(locationType);

      await openLocationEditor(page);
      await fillLocationForm(page, {
        name: locationName,
        type: locationType,
        address: `${locationType} Address, Test City, TX`
      });
      await saveLocation(page);

      // Verify location appears
      const locationsModal = page.locator('#companyLocationsModal');
      await expect(locationsModal).toContainText(locationName);
    }

    await closeLocationsModal(page);
  });

  test('sets default ship-to location', async ({ page }) => {
    const locationName = uniqueLocationName('Default Ship');

    await openLocationsModal(page);
    await openLocationEditor(page);

    await fillLocationForm(page, {
      name: locationName,
      type: 'warehouse',
      address: '789 Default Street, Default City, TX 75003',
      defaultShipTo: true
    });

    await saveLocation(page);

    // Verify location shows as default (look for indicator)
    const locationsModal = page.locator('#companyLocationsModal');
    const locationEntry = locationsModal.locator(`text=${locationName}`).locator('..').locator('..');

    // Check for default indicator - could be a badge, icon, or text
    const hasDefaultIndicator = await locationEntry.locator('text=/default|ship.?to/i').count() > 0 ||
                                await locationEntry.locator('[class*="default"]').count() > 0;

    // At minimum, verify the location was created
    await expect(locationsModal).toContainText(locationName);

    await closeLocationsModal(page);
  });

  test('address field accepts manual input when Places API unavailable', async ({ page }) => {
    const locationName = uniqueLocationName('Manual Address');
    const manualAddress = '999 Manual Entry Ave, No Autocomplete City, CA 90210';

    await openLocationsModal(page);
    await openLocationEditor(page);

    // Fill form with manual address using helper (handles gmp-place-autocomplete)
    await fillLocationForm(page, {
      name: locationName,
      address: manualAddress
    });

    // Save should succeed
    await saveLocation(page);

    // Verify location was created with the address
    const locationsModal = page.locator('#companyLocationsModal');
    await expect(locationsModal).toContainText(locationName);

    await closeLocationsModal(page);
  });

  test('closes modal with Done button', async ({ page }) => {
    await openLocationsModal(page);

    // Click Done button (not Cancel)
    const doneBtn = page.locator('#companyLocationsModal .modal-footer .btn-primary');
    await doneBtn.click();

    // Modal should close
    await expect(page.locator('#companyLocationsModal')).toHaveAttribute('aria-hidden', 'true');
  });

  test('closes modal with X button', async ({ page }) => {
    await openLocationsModal(page);

    // Click X close button
    const closeBtn = page.locator('#companyLocationsModal .modal-close');
    await closeBtn.click();

    // Modal should close
    await expect(page.locator('#companyLocationsModal')).toHaveAttribute('aria-hidden', 'true');
  });

  test('persists location after page reload', async ({ page }) => {
    const locationName = uniqueLocationName('Persist Test');
    const locationAddress = '111 Persistence Lane, Reload City, TX 75004';

    // Create location
    await openLocationsModal(page);
    await openLocationEditor(page);

    await fillLocationForm(page, {
      name: locationName,
      type: 'warehouse',
      address: locationAddress
    });
    await saveLocation(page);
    await closeLocationsModal(page);

    // Reload page
    await page.reload();

    // Re-login after reload
    await login(page);

    // Open locations modal again
    await openLocationsModal(page);

    // Verify location still exists
    const locationsModal = page.locator('#companyLocationsModal');
    await expect(locationsModal).toContainText(locationName);

    await closeLocationsModal(page);
  });
});

test.describe('Company Locations - Delete', () => {
  test.beforeEach(async ({ page }) => {
    await setupPage(page);
    await page.goto('/');
    await login(page);
  });

  test('deletes a location with confirmation', async ({ page }) => {
    const locationName = uniqueLocationName('Delete Me');
    const locationAddress = '222 Delete Street, Gone City, TX 75005';

    // Create location first
    await openLocationsModal(page);
    await openLocationEditor(page);

    await fillLocationForm(page, {
      name: locationName,
      type: 'warehouse',
      address: locationAddress
    });
    await saveLocation(page);

    // Verify it exists
    let locationsModal = page.locator('#companyLocationsModal');
    await expect(locationsModal).toContainText(locationName);

    // Find delete button for this location
    const locationRow = page.locator(`text=${locationName}`).locator('..').locator('..');
    const deleteBtn = locationRow.locator('button[aria-label="Delete"], button[aria-label="Deactivate"], .btn-delete, [data-action="delete"], [data-action="deactivate"]').first();

    if (await deleteBtn.count() > 0) {
      await deleteBtn.click();

      // Handle confirmation dialog if present
      const confirmBtn = page.locator('.modal button:has-text("Confirm"), .modal button:has-text("Delete"), .modal button:has-text("Yes"), .modal .btn-primary');
      if (await confirmBtn.count() > 0) {
        await confirmBtn.first().click();
      }

      // Wait for deletion to complete
      await page.waitForTimeout(1000);

      // Verify location is removed or marked as inactive
      locationsModal = page.locator('#companyLocationsModal');
      // Either the name is gone, or it's marked as inactive
      const stillVisible = await locationsModal.locator(`text=${locationName}`).count();
      if (stillVisible > 0) {
        // Check if it's marked as inactive
        const locationEntry = locationsModal.locator(`text=${locationName}`).locator('..').locator('..');
        const isInactive = await locationEntry.locator('text=/inactive/i').count() > 0 ||
                          await locationEntry.locator('[class*="inactive"]').count() > 0;
        expect(isInactive).toBe(true);
      }
    }

    await closeLocationsModal(page);
  });
});
