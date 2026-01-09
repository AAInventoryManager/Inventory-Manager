import dotenv from 'dotenv';

const rawEnvPath = process.env.ENV_PATH;
const envPath = rawEnvPath && rawEnvPath.trim()
  ? rawEnvPath
  : (process.env.CI ? '.env.test.ci' : '.env.test');

const EMPTY_ENV_KEYS = [
  'SUPABASE_URL',
  'SUPABASE_ANON_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'TEST_USER_PASSWORD',
  'TEST_APP_URL'
];

for (const key of EMPTY_ENV_KEYS) {
  if (process.env[key] === '') delete process.env[key];
}

dotenv.config({ path: envPath });

export { envPath };
