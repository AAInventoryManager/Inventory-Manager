-- Create receipt ingestion service account
-- This user is used for audit trails when receipts are ingested via email
-- UUID: 0d138ecc-fdca-47aa-af9f-712e091db791

INSERT INTO auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at,
  confirmation_token,
  recovery_token
)
VALUES (
  '0d138ecc-fdca-47aa-af9f-712e091db791',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'receipt-ingestion@system.inventorymanager.app',
  '',
  NOW(),
  '{"provider": "service_account", "providers": ["service_account"]}',
  '{"service_account": true, "service_name": "receipt_ingestion"}',
  NOW(),
  NOW(),
  '',
  ''
)
ON CONFLICT (id) DO NOTHING;
