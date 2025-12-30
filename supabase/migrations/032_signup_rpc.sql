-- Self-service signup RPC
-- Creates a company and links the authenticated user as admin

BEGIN;

CREATE OR REPLACE FUNCTION public.create_company_for_signup(
  p_name TEXT,
  p_slug TEXT,
  p_plan TEXT DEFAULT 'starter'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_email TEXT;
  v_company_id UUID;
  v_tier TEXT;
  v_final_slug TEXT;
  v_slug_suffix INTEGER := 0;
BEGIN
  -- Validate user is authenticated
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  -- Get user email
  v_user_email := auth.email();

  -- Check user doesn't already have a company
  IF EXISTS (SELECT 1 FROM public.company_members WHERE user_id = v_user_id) THEN
    RAISE EXCEPTION 'User already belongs to a company';
  END IF;

  -- Validate company name
  IF nullif(trim(p_name), '') IS NULL THEN
    RAISE EXCEPTION 'Company name required';
  END IF;

  -- Map plan to tier
  v_tier := CASE lower(trim(COALESCE(p_plan, 'starter')))
    WHEN 'starter' THEN 'starter'
    WHEN 'professional' THEN 'professional'
    WHEN 'business' THEN 'business'
    WHEN 'enterprise' THEN 'enterprise'
    ELSE 'starter'
  END;

  -- Generate unique slug
  v_final_slug := lower(trim(COALESCE(p_slug, '')));
  IF v_final_slug = '' THEN
    v_final_slug := lower(regexp_replace(trim(p_name), '[^a-zA-Z0-9]+', '-', 'g'));
    v_final_slug := regexp_replace(v_final_slug, '^-|-$', '', 'g');
  END IF;

  -- Handle slug collision by adding suffix
  WHILE EXISTS (SELECT 1 FROM public.companies WHERE slug = v_final_slug) LOOP
    v_slug_suffix := v_slug_suffix + 1;
    v_final_slug := lower(regexp_replace(trim(p_name), '[^a-zA-Z0-9]+', '-', 'g'));
    v_final_slug := regexp_replace(v_final_slug, '^-|-$', '', 'g');
    v_final_slug := v_final_slug || '-' || v_slug_suffix::TEXT;
  END LOOP;

  -- Generate company ID
  v_company_id := gen_random_uuid();

  -- Create company
  INSERT INTO public.companies (id, name, slug, onboarding_state, base_subscription_tier, settings)
  VALUES (
    v_company_id,
    trim(p_name),
    v_final_slug,
    'SUBSCRIPTION_ACTIVE',
    v_tier,
    jsonb_build_object('signup_plan', v_tier, 'signup_date', now())
  );

  -- Add user as admin
  INSERT INTO public.company_members (company_id, user_id, role, is_super_user)
  VALUES (v_company_id, v_user_id, 'admin', false);

  -- Create profile if not exists
  INSERT INTO public.profiles (user_id, display_name, email)
  VALUES (v_user_id, split_part(COALESCE(v_user_email, ''), '@', 1), v_user_email)
  ON CONFLICT (user_id) DO UPDATE SET
    email = EXCLUDED.email
  WHERE public.profiles.email IS NULL OR public.profiles.email = '';

  -- Audit log
  INSERT INTO public.audit_log (
    action,
    table_name,
    record_id,
    company_id,
    user_id,
    new_values
  ) VALUES (
    'INSERT',
    'companies',
    v_company_id,
    v_company_id,
    v_user_id,
    jsonb_build_object(
      'event_name', 'company_created_via_signup',
      'company_id', v_company_id,
      'company_name', trim(p_name),
      'tier', v_tier,
      'user_id', v_user_id,
      'timestamp', now()
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'company_id', v_company_id,
    'company_name', trim(p_name),
    'company_slug', v_final_slug,
    'tier', v_tier
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_company_for_signup(TEXT, TEXT, TEXT) TO authenticated;

COMMIT;
