import dotenv from 'dotenv';

const envPath = process.env.ENV_PATH || (process.env.CI ? '.env.test.ci' : '.env.test');
dotenv.config({ path: envPath });
