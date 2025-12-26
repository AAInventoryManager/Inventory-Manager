-- Phase 2: tier overrides and super user tier bypass
-- Feature IDs: inventory.billing.tier_override, inventory.entitlements.tier_resolution, inventory.auth.super_user

BEGIN;

-- Tier enum for manual overrides
DO $$
BEGIN
    CREATE TYPE public.tier_level AS ENUM ('starter','professional','business','enterprise');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Manual tier override fields on companies
ALTER TABLE public.companies
    ADD COLUMN IF NOT EXISTS tier_override public.tier_level,
    ADD COLUMN IF NOT EXISTS tier_override_reason TEXT,
    ADD COLUMN IF NOT EXISTS tier_override_set_by UUID REFERENCES auth.users(id),
    ADD COLUMN IF NOT EXISTS tier_override_set_at TIMESTAMPTZ;

COMMENT ON COLUMN public.companies.tier_override IS 'Manual tier override set by super user; higher precedence than billing tier';
COMMENT ON COLUMN public.companies.tier_override_reason IS 'Reason for manual tier override';
COMMENT ON COLUMN public.companies.tier_override_set_by IS 'Super user who set the manual tier override';
COMMENT ON COLUMN public.companies.tier_override_set_at IS 'Timestamp when manual tier override was set';

-- Tier ordering helper (explicit)
CREATE OR REPLACE FUNCTION public.tier_rank(p_tier TEXT)
RETURNS INTEGER
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
    SELECT CASE lower(trim(COALESCE(p_tier, '')))
        WHEN 'starter' THEN 1
        WHEN 'professional' THEN 2
        WHEN 'business' THEN 3
        WHEN 'enterprise' THEN 4
        ELSE 0
    END;
$$;

GRANT EXECUTE ON FUNCTION public.tier_rank(TEXT) TO authenticated;

-- Base tier resolution (billing + override, no super user bypass)
CREATE OR REPLACE FUNCTION public.resolve_company_tier(p_company_id UUID)
RETURNS TABLE (
    subscription_tier TEXT,
    override_tier TEXT,
    effective_tier TEXT,
    tier_source TEXT,
    billing_state TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_count INTEGER := 0;
    v_status TEXT := NULL;
    v_subscription_tier TEXT := 'starter';
    v_override_tier public.tier_level := NULL;
    v_effective_tier TEXT := 'starter';
    v_source TEXT := 'billing';
    v_billing_state TEXT := 'none';
BEGIN
    IF p_company_id IS NULL THEN
        RETURN QUERY SELECT 'starter'::text, NULL::text, 'starter'::text, 'billing'::text, 'none'::text;
        RETURN;
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM public.billing_subscriptions bs
    WHERE bs.company_id = p_company_id
      AND bs.status IN ('active','trial','grace')
      AND (
        bs.status <> 'trial'
        OR (bs.trial_end IS NOT NULL AND bs.trial_end > now())
      )
      AND (
        bs.status <> 'grace'
        OR (bs.grace_end IS NOT NULL AND bs.grace_end > now())
      );

    IF v_count = 1 THEN
        SELECT bs.status, bpm.tier
        INTO v_status, v_subscription_tier
        FROM public.billing_subscriptions bs
        JOIN public.billing_price_map bpm
          ON bpm.provider = bs.provider
         AND bpm.price_id = bs.price_id
         AND bpm.is_active = true
        WHERE bs.company_id = p_company_id
          AND bs.status IN ('active','trial','grace')
          AND (
            bs.status <> 'trial'
            OR (bs.trial_end IS NOT NULL AND bs.trial_end > now())
          )
          AND (
            bs.status <> 'grace'
            OR (bs.grace_end IS NOT NULL AND bs.grace_end > now())
          )
        ORDER BY bs.updated_at DESC NULLS LAST
        LIMIT 1;

        IF v_status IN ('active','trial','grace') THEN
            v_billing_state := v_status;
        ELSE
            v_billing_state := 'none';
        END IF;

        IF v_subscription_tier IS NULL OR v_subscription_tier NOT IN ('starter','professional','business','enterprise') THEN
            v_subscription_tier := 'starter';
        END IF;
    ELSE
        IF v_count > 1 THEN
            RAISE LOG 'Ambiguous billing subscriptions for company %', p_company_id;
        END IF;
        v_subscription_tier := 'starter';
        v_billing_state := 'none';
    END IF;

    SELECT tier_override
    INTO v_override_tier
    FROM public.companies
    WHERE id = p_company_id;

    v_effective_tier := v_subscription_tier;
    v_source := 'billing';

    IF v_override_tier IS NOT NULL THEN
        IF public.tier_rank(v_override_tier::text) >= public.tier_rank(v_subscription_tier) THEN
            v_effective_tier := v_override_tier::text;
            v_source := 'override';
        END IF;
    END IF;

    RETURN QUERY SELECT
        v_subscription_tier,
        CASE WHEN v_override_tier IS NULL THEN NULL ELSE v_override_tier::text END,
        v_effective_tier,
        v_source,
        v_billing_state;
END;
$$;

-- Tier resolution with super user bypass (authoritative API)
DROP FUNCTION IF EXISTS public.get_company_tier(UUID) CASCADE;
CREATE OR REPLACE FUNCTION public.get_company_tier(p_company_id UUID)
RETURNS TABLE (
    effective_tier TEXT,
    tier_source TEXT,
    billing_state TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_res RECORD;
BEGIN
    SELECT * INTO v_res FROM public.resolve_company_tier(p_company_id);
    IF public.is_super_user() THEN
        RETURN QUERY SELECT 'enterprise'::text, 'super_user'::text, COALESCE(v_res.billing_state, 'none');
        RETURN;
    END IF;

    RETURN QUERY SELECT v_res.effective_tier, v_res.tier_source, v_res.billing_state;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_tier(UUID) TO authenticated;

-- Tier details for super user company administration
DROP FUNCTION IF EXISTS public.get_company_tier_details(UUID);
CREATE OR REPLACE FUNCTION public.get_company_tier_details(p_company_id UUID)
RETURNS TABLE (
    subscription_tier TEXT,
    override_tier TEXT,
    effective_tier TEXT,
    tier_source TEXT,
    billing_state TEXT,
    override_reason TEXT,
    override_set_by UUID,
    override_set_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_res RECORD;
    v_reason TEXT;
    v_set_by UUID;
    v_set_at TIMESTAMPTZ;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    SELECT * INTO v_res FROM public.resolve_company_tier(p_company_id);

    SELECT tier_override_reason, tier_override_set_by, tier_override_set_at
    INTO v_reason, v_set_by, v_set_at
    FROM public.companies
    WHERE id = p_company_id;

    RETURN QUERY SELECT
        v_res.subscription_tier,
        v_res.override_tier,
        v_res.effective_tier,
        v_res.tier_source,
        v_res.billing_state,
        v_reason,
        v_set_by,
        v_set_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_company_tier_details(UUID) TO authenticated;

-- Tier access helper with super user bypass
CREATE OR REPLACE FUNCTION public.has_tier_access(p_company_id UUID, p_required_tier TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_required_rank INTEGER := 0;
    v_effective TEXT := NULL;
BEGIN
    IF p_company_id IS NULL THEN
        RETURN false;
    END IF;

    IF public.is_super_user() THEN
        RETURN true;
    END IF;

    v_required_rank := public.tier_rank(p_required_tier);
    IF v_required_rank = 0 THEN
        RETURN false;
    END IF;

    SELECT effective_tier
    INTO v_effective
    FROM public.resolve_company_tier(p_company_id);

    RETURN public.tier_rank(v_effective) >= v_required_rank;
END;
$$;

GRANT EXECUTE ON FUNCTION public.has_tier_access(UUID, TEXT) TO authenticated;

-- Super user tier override RPC
CREATE OR REPLACE FUNCTION public.set_company_tier_override(
    p_company_id UUID,
    p_tier TEXT,
    p_reason TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_new_override public.tier_level;
    v_old_override public.tier_level;
    v_old_reason TEXT;
    v_old_set_by UUID;
    v_old_set_at TIMESTAMPTZ;
    v_effective RECORD;
    v_reason TEXT := NULL;
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN jsonb_build_object('success', false, 'error', 'Unauthorized');
    END IF;

    IF p_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Missing company_id');
    END IF;

    v_reason := NULLIF(trim(COALESCE(p_reason, '')), '');
    IF v_reason IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Reason required');
    END IF;

    IF p_tier IS NULL OR trim(p_tier) = '' THEN
        v_new_override := NULL;
    ELSE
        BEGIN
            v_new_override := lower(trim(p_tier))::public.tier_level;
        EXCEPTION
            WHEN invalid_text_representation THEN
                RETURN jsonb_build_object('success', false, 'error', 'Invalid tier');
        END;
    END IF;

    SELECT tier_override, tier_override_reason, tier_override_set_by, tier_override_set_at
    INTO v_old_override, v_old_reason, v_old_set_by, v_old_set_at
    FROM public.companies
    WHERE id = p_company_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Company not found');
    END IF;

    UPDATE public.companies
    SET
        tier_override = v_new_override,
        tier_override_reason = v_reason,
        tier_override_set_by = auth.uid(),
        tier_override_set_at = now(),
        updated_at = now()
    WHERE id = p_company_id;

    INSERT INTO public.audit_log (
        action, table_name, record_id, company_id, user_id, reason, old_values, new_values
    ) VALUES (
        'UPDATE',
        'companies',
        p_company_id,
        p_company_id,
        auth.uid(),
        v_reason,
        jsonb_build_object(
            'tier_override', v_old_override,
            'tier_override_reason', v_old_reason,
            'tier_override_set_by', v_old_set_by,
            'tier_override_set_at', v_old_set_at
        ),
        jsonb_build_object(
            'tier_override', v_new_override,
            'tier_override_reason', v_reason,
            'tier_override_set_by', auth.uid(),
            'tier_override_set_at', now()
        )
    );

    RAISE LOG 'tier_override_change %', jsonb_build_object(
        'company_id', p_company_id,
        'set_by', auth.uid(),
        'tier_override', v_new_override,
        'reason', v_reason
    );

    SELECT * INTO v_effective FROM public.resolve_company_tier(p_company_id);

    RETURN jsonb_build_object(
        'success', true,
        'effective_tier', v_effective.effective_tier,
        'tier_source', v_effective.tier_source,
        'billing_state', v_effective.billing_state,
        'override_tier', v_effective.override_tier
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_company_tier_override(UUID, TEXT, TEXT) TO authenticated;

-- Update get_my_companies to use effective tier resolution
DROP FUNCTION IF EXISTS public.get_my_companies();
CREATE OR REPLACE FUNCTION public.get_my_companies()
RETURNS TABLE (
    company_id UUID,
    company_name TEXT,
    company_slug TEXT,
    my_role TEXT,
    is_super_user BOOLEAN,
    member_count BIGINT,
    company_tier TEXT,
    tier_source TEXT,
    billing_state TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF public.is_super_user() THEN
        RETURN QUERY
        SELECT
            c.id,
            c.name,
            c.slug,
            'super_user'::text,
            true,
            (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
            tier.effective_tier,
            tier.tier_source,
            tier.billing_state
        FROM public.companies c
        CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
        WHERE c.is_active = true
        ORDER BY c.name;
    ELSE
        RETURN QUERY
        SELECT
            c.id,
            c.name,
            c.slug,
            cm.role,
            cm.is_super_user,
            (SELECT COUNT(*) FROM public.company_members cm2 WHERE cm2.company_id = c.id),
            tier.effective_tier,
            tier.tier_source,
            tier.billing_state
        FROM public.companies c
        JOIN public.company_members cm ON cm.company_id = c.id
        CROSS JOIN LATERAL public.resolve_company_tier(c.id) AS tier
        WHERE cm.user_id = auth.uid()
        AND c.is_active = true
        ORDER BY c.name;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_companies() TO authenticated;

-- Snapshot access policy and RPC
DROP POLICY IF EXISTS "Admins can view snapshots" ON public.inventory_snapshots;
CREATE POLICY "Admins can view snapshots"
    ON public.inventory_snapshots FOR SELECT
    USING (
        public.has_tier_access(company_id, 'business')
        AND (
            public.check_permission(company_id, 'snapshots:view')
            OR public.user_can_delete(company_id)
        )
    );

CREATE OR REPLACE FUNCTION public.get_snapshots(p_company_id UUID)
RETURNS TABLE (
    id UUID,
    name TEXT,
    description TEXT,
    snapshot_type TEXT,
    items_count INTEGER,
    total_quantity INTEGER,
    created_at TIMESTAMPTZ,
    created_by_email TEXT,
    was_restored BOOLEAN,
    restored_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.has_tier_access(p_company_id, 'business') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    IF NOT (
        public.check_permission(p_company_id, 'snapshots:view')
        OR public.user_can_delete(p_company_id)
    ) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    RETURN QUERY
    SELECT s.id, s.name, s.description, s.snapshot_type, s.items_count, s.total_quantity,
        s.created_at, u.email, (s.restored_at IS NOT NULL), s.restored_at
    FROM public.inventory_snapshots s
    LEFT JOIN auth.users u ON u.id = s.created_by
    WHERE s.company_id = p_company_id
    ORDER BY s.created_at DESC;
END;
$$;

-- Audit log policy and RPCs
DROP POLICY IF EXISTS "Audit log access" ON public.audit_log;
CREATE POLICY "Audit log access"
    ON public.audit_log FOR SELECT
    USING (
        public.has_tier_access(company_id, 'enterprise')
        AND public.check_permission(company_id, 'audit_log:view')
    );

CREATE OR REPLACE FUNCTION public.get_audit_log(
    p_company_id UUID,
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0,
    p_table_name TEXT DEFAULT NULL,
    p_action TEXT DEFAULT NULL
)
RETURNS TABLE (
    id UUID, action TEXT, table_name TEXT, record_id UUID,
    user_email TEXT, user_role TEXT, old_values JSONB, new_values JSONB,
    changed_fields TEXT[], created_at TIMESTAMPTZ, is_rolled_back BOOLEAN, rolled_back_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.has_tier_access(p_company_id, 'enterprise') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    IF NOT public.check_permission(p_company_id, 'audit_log:view') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    RETURN QUERY
    SELECT 
        a.id, a.action, a.table_name, a.record_id,
        a.user_email, a.user_role, a.old_values, a.new_values,
        a.changed_fields, a.created_at, (a.rolled_back_at IS NOT NULL), a.rolled_back_at
    FROM public.audit_log a
    WHERE a.company_id = p_company_id
    AND (p_table_name IS NULL OR a.table_name = p_table_name)
    AND (p_action IS NULL OR a.action = p_action)
    ORDER BY a.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.undo_action(p_audit_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_audit RECORD;
    v_required_permission TEXT;
BEGIN
    SELECT * INTO v_audit
    FROM public.audit_log
    WHERE id = p_audit_id AND rolled_back_at IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Audit entry not found or already rolled back');
    END IF;

    IF NOT public.has_tier_access(v_audit.company_id, 'enterprise') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(v_audit.company_id, 'audit_log:view') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF v_audit.action IN ('DELETE', 'BULK_DELETE') THEN
        v_required_permission := 'items:restore';
    ELSIF v_audit.action = 'UPDATE' THEN
        v_required_permission := 'items:edit';
    ELSIF v_audit.action = 'INSERT' THEN
        v_required_permission := 'items:delete';
    ELSE
        RETURN json_build_object('success', false, 'error', 'Cannot undo this action type');
    END IF;

    IF v_required_permission IS NOT NULL AND NOT public.check_permission(v_audit.company_id, v_required_permission) THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    CASE v_audit.action
        WHEN 'DELETE', 'BULK_DELETE' THEN
            IF v_audit.table_name = 'inventory_items' AND v_audit.old_values IS NOT NULL THEN
                UPDATE public.inventory_items
                SET 
                    deleted_at = NULL,
                    deleted_by = NULL,
                    name = COALESCE(v_audit.old_values->>'name', name),
                    description = COALESCE(v_audit.old_values->>'description', description),
                    quantity = COALESCE((v_audit.old_values->>'quantity')::integer, quantity)
                WHERE id = v_audit.record_id
                AND company_id = v_audit.company_id;  -- Company guard
            END IF;
            
        WHEN 'UPDATE' THEN
            IF v_audit.table_name = 'inventory_items' AND v_audit.old_values IS NOT NULL THEN
                UPDATE public.inventory_items
                SET 
                    name = COALESCE(v_audit.old_values->>'name', name),
                    description = COALESCE(v_audit.old_values->>'description', description),
                    quantity = COALESCE((v_audit.old_values->>'quantity')::integer, quantity),
                    sku = v_audit.old_values->>'sku',
                    updated_at = now()
                WHERE id = v_audit.record_id
                AND company_id = v_audit.company_id;  -- Company guard
            END IF;
            
        WHEN 'INSERT' THEN
            IF v_audit.table_name = 'inventory_items' THEN
                UPDATE public.inventory_items
                SET deleted_at = now(), deleted_by = auth.uid()
                WHERE id = v_audit.record_id
                AND company_id = v_audit.company_id;  -- Company guard
            END IF;
    END CASE;

    UPDATE public.audit_log
    SET rolled_back_at = now(), rolled_back_by = auth.uid(), rollback_reason = p_reason
    WHERE id = p_audit_id;

    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, reason, old_values)
    VALUES ('ROLLBACK', v_audit.table_name, v_audit.record_id, v_audit.company_id, auth.uid(),
        'Undo of action ' || v_audit.id::text,
        jsonb_build_object('original_audit_id', p_audit_id, 'original_action', v_audit.action));

    RETURN json_build_object('success', true);
END;
$$;

-- Role configuration policy
DROP POLICY IF EXISTS "Super users can update role configs" ON public.role_configurations;
CREATE POLICY "Super users can update role configs"
    ON public.role_configurations FOR UPDATE
    USING (public.is_super_user())
    WITH CHECK (public.is_super_user());

-- Company members RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Users can view company members" ON public.company_members;
CREATE POLICY "Users can view company members"
    ON public.company_members FOR SELECT
    USING (
        user_id = auth.uid()
        OR (
            public.has_tier_access(company_id, 'business')
            AND public.check_permission(company_id, 'members:view')
        )
    );

DROP POLICY IF EXISTS "Admins can add members" ON public.company_members;
CREATE POLICY "Admins can add members"
    ON public.company_members FOR INSERT
    WITH CHECK (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'members:invite')
        AND is_super_user = false
    );

DROP POLICY IF EXISTS "Admins can update member roles" ON public.company_members;
CREATE POLICY "Admins can update member roles"
    ON public.company_members FOR UPDATE
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'members:change_role')
    )
    WITH CHECK (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'members:change_role')
        AND is_super_user = false
    );

-- Invitations RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Admins can view invitations" ON public.invitations;
CREATE POLICY "Admins can view invitations"
    ON public.invitations FOR SELECT
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'members:invite')
    );

DROP POLICY IF EXISTS "Admins can create invitations" ON public.invitations;
CREATE POLICY "Admins can create invitations"
    ON public.invitations FOR INSERT
    WITH CHECK (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'members:invite')
    );

DROP POLICY IF EXISTS "Admins can update invitations" ON public.invitations;
CREATE POLICY "Admins can update invitations"
    ON public.invitations FOR UPDATE
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'members:invite')
    );

-- Role change requests RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Users can view own requests" ON public.role_change_requests;
CREATE POLICY "Users can view own requests"
    ON public.role_change_requests FOR SELECT
    USING (
        public.has_tier_access(company_id, 'business')
        AND (
            user_id = auth.uid()
            OR public.check_permission(company_id, 'members:change_role')
        )
    );

DROP POLICY IF EXISTS "Users can create requests" ON public.role_change_requests;
CREATE POLICY "Users can create requests"
    ON public.role_change_requests FOR INSERT
    WITH CHECK (
        user_id = auth.uid()
        AND public.has_tier_access(company_id, 'business')
    );

DROP POLICY IF EXISTS "Admins can update requests" ON public.role_change_requests;
CREATE POLICY "Admins can update requests"
    ON public.role_change_requests FOR UPDATE
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'members:change_role')
    );

-- Invite user RPC: tier + permission enforcement
CREATE OR REPLACE FUNCTION public.invite_user(
    p_company_id UUID,
    p_email TEXT,
    p_role TEXT DEFAULT 'member'
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_token TEXT;
    v_company_name TEXT;
BEGIN
    IF NOT public.has_tier_access(p_company_id, 'business') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(p_company_id, 'members:invite') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF p_role NOT IN ('admin', 'member', 'viewer') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid role');
    END IF;

    -- Check if user already exists in any company
    IF EXISTS (
        SELECT 1 FROM public.company_members cm
        JOIN auth.users u ON u.id = cm.user_id
        WHERE u.email = p_email
    ) THEN
        RETURN json_build_object('success', false, 'error', 'User is already a member of a company');
    END IF;

    SELECT name INTO v_company_name FROM public.companies WHERE id = p_company_id;

    INSERT INTO public.invitations (company_id, email, role, invited_by)
    VALUES (p_company_id, p_email, p_role, auth.uid())
    ON CONFLICT (company_id, email)
    DO UPDATE SET
        role = EXCLUDED.role,
        token = replace(gen_random_uuid()::text, '-', ''),
        invited_by = EXCLUDED.invited_by,
        expires_at = now() + interval '7 days',
        accepted_at = NULL
    RETURNING token INTO v_token;

    RETURN json_build_object(
        'success', true,
        'token', v_token,
        'invite_url', 'https://inventory.modulus-software.com/?invite=' || v_token,
        'company_name', v_company_name
    );
END;
$$;

-- Accept invitation RPC: tier enforcement
CREATE OR REPLACE FUNCTION public.accept_invitation(invitation_token TEXT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invitation RECORD;
    v_admin_id UUID;
    v_existing_company UUID;
BEGIN
    -- Check if user already has a company (one company per user)
    SELECT company_id INTO v_existing_company
    FROM public.company_members
    WHERE user_id = auth.uid();

    IF v_existing_company IS NOT NULL THEN
        RETURN json_build_object('success', false, 'error', 'You are already a member of a company');
    END IF;

    SELECT * INTO v_invitation
    FROM public.invitations
    WHERE token = invitation_token
    AND expires_at > now()
    AND accepted_at IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Invalid or expired invitation');
    END IF;

    IF NOT public.has_tier_access(v_invitation.company_id, 'business') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF v_invitation.email != (SELECT email FROM auth.users WHERE id = auth.uid()) THEN
        RETURN json_build_object('success', false, 'error', 'Invitation was sent to a different email');
    END IF;

    -- Find an admin to assign
    SELECT user_id INTO v_admin_id
    FROM public.company_members
    WHERE company_id = v_invitation.company_id AND role = 'admin'
    LIMIT 1;

    INSERT INTO public.company_members (company_id, user_id, role, invited_by, assigned_admin_id)
    VALUES (v_invitation.company_id, auth.uid(), v_invitation.role, v_invitation.invited_by, COALESCE(v_admin_id, v_invitation.invited_by));

    UPDATE public.invitations SET accepted_at = now() WHERE id = v_invitation.id;

    RETURN json_build_object('success', true, 'company_id', v_invitation.company_id, 'role', v_invitation.role);
END;
$$;

-- Role change request RPC: tier enforcement
CREATE OR REPLACE FUNCTION public.request_role_change(
    p_requested_role TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current_role TEXT;
    v_company_id UUID;
    v_request_id UUID;
BEGIN
    SELECT role, company_id INTO v_current_role, v_company_id
    FROM public.company_members
    WHERE user_id = auth.uid();

    IF v_current_role IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Not a member of any company');
    END IF;

    IF NOT public.has_tier_access(v_company_id, 'business') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF p_requested_role NOT IN ('admin', 'member', 'viewer') THEN
        RETURN json_build_object('success', false, 'error', 'Invalid role');
    END IF;

    IF p_requested_role = v_current_role THEN
        RETURN json_build_object('success', false, 'error', 'You already have this role');
    END IF;

    IF EXISTS (SELECT 1 FROM public.role_change_requests WHERE user_id = auth.uid() AND status = 'pending') THEN
        RETURN json_build_object('success', false, 'error', 'Pending request already exists');
    END IF;

    INSERT INTO public.role_change_requests (company_id, user_id, current_role_name, requested_role, reason)
    VALUES (v_company_id, auth.uid(), v_current_role, p_requested_role, p_reason)
    RETURNING id INTO v_request_id;

    RETURN json_build_object('success', true, 'request_id', v_request_id);
END;
$$;

-- Process role change request RPC: tier + permission enforcement
CREATE OR REPLACE FUNCTION public.process_role_request(
    p_request_id UUID,
    p_approved BOOLEAN,
    p_admin_notes TEXT DEFAULT NULL
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_request RECORD;
BEGIN
    SELECT * INTO v_request
    FROM public.role_change_requests
    WHERE id = p_request_id AND status = 'pending';

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Request not found');
    END IF;

    IF NOT public.has_tier_access(v_request.company_id, 'business') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(v_request.company_id, 'members:change_role') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    UPDATE public.role_change_requests
    SET
        status = CASE WHEN p_approved THEN 'approved' ELSE 'denied' END,
        reviewed_by = auth.uid(),
        reviewed_at = now(),
        admin_notes = p_admin_notes
    WHERE id = p_request_id;

    IF p_approved THEN
        UPDATE public.company_members
        SET role = v_request.requested_role
        WHERE user_id = v_request.user_id AND company_id = v_request.company_id;
    END IF;

    RETURN json_build_object('success', true, 'approved', p_approved);
END;
$$;

-- Remove member RPC: tier + permission enforcement
CREATE OR REPLACE FUNCTION public.remove_company_member(p_user_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
    v_target_is_super BOOLEAN;
BEGIN
    -- Get target user's company
    SELECT company_id, is_super_user INTO v_company_id, v_target_is_super
    FROM public.company_members
    WHERE user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Member not found');
    END IF;

    IF NOT public.has_tier_access(v_company_id, 'business') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    -- Cannot remove super users (except by themselves)
    IF v_target_is_super AND p_user_id != auth.uid() THEN
        RETURN json_build_object('success', false, 'error', 'Cannot remove super user');
    END IF;

    -- Verify permission
    IF NOT public.check_permission(v_company_id, 'members:remove') AND p_user_id != auth.uid() THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    DELETE FROM public.company_members WHERE user_id = p_user_id;

    RETURN json_build_object('success', true);
END;
$$;

-- Metrics and reporting: company dashboard metrics
CREATE OR REPLACE FUNCTION public.get_company_dashboard_metrics(
    p_company_id UUID,
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_days INTEGER;
    v_result JSONB;
BEGIN
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'Company required';
    END IF;

    IF NOT public.has_tier_access(p_company_id, 'professional') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    IF NOT public.check_permission(p_company_id, 'metrics:view') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    v_days := GREATEST(COALESCE(p_days, 30), 1);

    SELECT jsonb_build_object(
        'current', jsonb_build_object(
            'total_items', (
                SELECT COUNT(*) FROM public.inventory_items
                WHERE company_id = p_company_id AND deleted_at IS NULL
            ),
            'total_quantity', (
                SELECT COALESCE(SUM(quantity), 0) FROM public.inventory_items
                WHERE company_id = p_company_id AND deleted_at IS NULL
            ),
            'low_stock_count', (
                SELECT COUNT(*) FROM public.inventory_items
                WHERE company_id = p_company_id
                  AND deleted_at IS NULL
                  AND low_stock_qty IS NOT NULL
                  AND quantity <= low_stock_qty
            ),
            'active_members', (
                SELECT COUNT(*) FROM public.company_members
                WHERE company_id = p_company_id
            ),
            'snapshot_count', (
                SELECT COUNT(*) FROM public.inventory_snapshots
                WHERE company_id = p_company_id
            )
        ),
        'activity', (
            SELECT jsonb_build_object(
                'total_updates', COALESCE(SUM(CASE WHEN action_type = 'update' THEN action_count ELSE 0 END), 0),
                'total_deletes', COALESCE(SUM(CASE WHEN action_type IN ('delete','bulk_delete') THEN action_count ELSE 0 END), 0),
                'total_restores', COALESCE(SUM(CASE WHEN action_type = 'restore' THEN action_count ELSE 0 END), 0),
                'total_rollbacks', COALESCE(SUM(CASE WHEN action_type = 'rollback' THEN action_count ELSE 0 END), 0),
                'records_affected', COALESCE(SUM(records_affected), 0),
                'quantity_removed', COALESCE(SUM(quantity_removed), 0),
                'quantity_added', COALESCE(SUM(quantity_added), 0)
            )
            FROM public.action_metrics
            WHERE company_id = p_company_id
              AND metric_date >= CURRENT_DATE - v_days
        ),
        'daily', (
            SELECT COALESCE(jsonb_agg(d ORDER BY d.metric_date DESC), '[]'::jsonb)
            FROM (
                SELECT metric_date,
                    action_type,
                    SUM(action_count) AS action_count,
                    SUM(records_affected) AS records_affected
                FROM public.action_metrics
                WHERE company_id = p_company_id
                  AND metric_date >= CURRENT_DATE - v_days
                GROUP BY metric_date, action_type
            ) d
        ),
        'top_users', (
            SELECT COALESCE(jsonb_agg(u), '[]'::jsonb)
            FROM (
                SELECT am.user_id,
                    p.email,
                    SUM(am.action_count) AS total_actions
                FROM public.action_metrics am
                LEFT JOIN public.profiles p ON p.user_id = am.user_id
                WHERE am.company_id = p_company_id
                  AND am.metric_date >= CURRENT_DATE - v_days
                GROUP BY am.user_id, p.email
                ORDER BY total_actions DESC
                LIMIT 5
            ) u
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;

-- Platform metrics dashboard RPC (super user only)
CREATE OR REPLACE FUNCTION public.get_platform_dashboard_metrics(
    p_days INTEGER DEFAULT 30
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_days INTEGER;
    v_result JSONB;
BEGIN
    IF NOT public.is_super_user() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    v_days := GREATEST(COALESCE(p_days, 30), 1);

    SELECT jsonb_build_object(
        'platform', jsonb_build_object(
            'total_companies', (SELECT COUNT(*) FROM public.companies),
            'total_users', (SELECT COUNT(DISTINCT user_id) FROM public.company_members),
            'total_items', (SELECT COUNT(*) FROM public.inventory_items WHERE deleted_at IS NULL),
            'total_orders', (SELECT COUNT(*) FROM public.orders WHERE deleted_at IS NULL)
        ),
        'activity', jsonb_build_object(
            'total_actions', (
                SELECT COALESCE(SUM(action_count), 0)
                FROM public.action_metrics
                WHERE metric_date >= CURRENT_DATE - v_days
            ),
            'active_companies', (
                SELECT COUNT(DISTINCT company_id)
                FROM public.action_metrics
                WHERE metric_date >= CURRENT_DATE - v_days
            ),
            'active_users', (
                SELECT COUNT(DISTINCT user_id)
                FROM public.action_metrics
                WHERE metric_date >= CURRENT_DATE - v_days
            )
        ),
        'companies', (
            SELECT COALESCE(jsonb_agg(c), '[]'::jsonb)
            FROM (
                SELECT co.id,
                    co.name,
                    (SELECT COUNT(*) FROM public.company_members cm WHERE cm.company_id = co.id) AS member_count,
                    (SELECT COUNT(*) FROM public.inventory_items ii WHERE ii.company_id = co.id AND ii.deleted_at IS NULL) AS item_count,
                    COALESCE((
                        SELECT SUM(action_count) FROM public.action_metrics am
                        WHERE am.company_id = co.id
                          AND am.metric_date >= CURRENT_DATE - v_days
                    ), 0) AS recent_actions
                FROM public.companies co
                ORDER BY recent_actions DESC
                LIMIT 20
            ) c
        ),
        'daily', (
            SELECT COALESCE(jsonb_agg(d ORDER BY d.metric_date DESC), '[]'::jsonb)
            FROM (
                SELECT metric_date,
                    SUM(action_count) AS total_actions,
                    COUNT(DISTINCT company_id) AS active_companies
                FROM public.action_metrics
                WHERE metric_date >= CURRENT_DATE - v_days
                GROUP BY metric_date
            ) d
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$;

-- Platform metrics summary RPC
CREATE OR REPLACE FUNCTION public.get_platform_metrics()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;

    RETURN json_build_object(
        'total_companies', (SELECT COUNT(*) FROM public.companies),
        'active_companies', (SELECT COUNT(*) FROM public.companies WHERE is_active = true),
        'total_users', (SELECT COUNT(*) FROM auth.users),
        'total_items', (SELECT COUNT(*) FROM public.inventory_items WHERE deleted_at IS NULL),
        'total_deleted_items', (SELECT COUNT(*) FROM public.inventory_items WHERE deleted_at IS NOT NULL),
        'companies_breakdown', (
            SELECT json_agg(row_to_json(t))
            FROM (
                SELECT 
                    c.name,
                    (SELECT COUNT(*) FROM public.company_members WHERE company_id = c.id) as users,
                    (SELECT COUNT(*) FROM public.inventory_items WHERE company_id = c.id AND deleted_at IS NULL) as items,
                    (SELECT COUNT(*) FROM public.inventory_items WHERE company_id = c.id AND deleted_at IS NOT NULL) as deleted_items
                FROM public.companies c WHERE c.is_active = true
            ) t
        )
    );
END;
$$;

-- Action metrics RPC
CREATE OR REPLACE FUNCTION public.get_action_metrics(p_company_id UUID DEFAULT NULL, p_days INTEGER DEFAULT 30)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF NOT public.is_super_user() THEN
        RETURN json_build_object('error', 'Unauthorized');
    END IF;

    IF p_company_id IS NOT NULL THEN
        IF NOT public.has_tier_access(p_company_id, 'professional') THEN
            RETURN json_build_object('error', 'Feature not available for current plan');
        END IF;
    END IF;

    RETURN json_build_object(
        'period_days', p_days,
        'total_deletes', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'delete'),
        'total_updates', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'update'),
        'total_restores', (SELECT COALESCE(SUM(action_count), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days AND action_type = 'restore'),
        'quantity_removed', (SELECT COALESCE(SUM(quantity_removed), 0) FROM public.action_metrics WHERE (p_company_id IS NULL OR company_id = p_company_id) AND metric_date >= CURRENT_DATE - p_days)
    );
END;
$$;

-- Action metrics RLS
DROP POLICY IF EXISTS "Super users can view metrics" ON public.action_metrics;
DROP POLICY IF EXISTS "Metrics access" ON public.action_metrics;
CREATE POLICY "Metrics access"
    ON public.action_metrics FOR SELECT
    USING (public.is_super_user());

-- Low stock report RPC
CREATE OR REPLACE FUNCTION public.get_low_stock_items(
    p_category TEXT DEFAULT NULL,
    p_location TEXT DEFAULT NULL,
    p_include_zero BOOLEAN DEFAULT true,
    p_urgency TEXT DEFAULT 'all',
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    sku TEXT,
    quantity INTEGER,
    reorder_point INTEGER,
    reorder_quantity INTEGER,
    deficit INTEGER,
    urgency TEXT,
    category TEXT,
    location TEXT,
    unit_cost NUMERIC,
    supplier TEXT,
    last_reorder_date TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
    v_limit INTEGER;
    v_offset INTEGER;
BEGIN
    v_company_id := public.get_user_company_id();
    IF v_company_id IS NULL THEN
        RAISE EXCEPTION 'Company required';
    END IF;

    IF NOT public.has_tier_access(v_company_id, 'professional') THEN
        RAISE EXCEPTION 'Feature not available for current plan';
    END IF;

    IF NOT public.check_permission(v_company_id, 'items:view') THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    v_limit := GREATEST(COALESCE(p_limit, 50), 1);
    v_offset := GREATEST(COALESCE(p_offset, 0), 0);

    RETURN QUERY
    SELECT
        i.id,
        i.name,
        i.sku,
        i.quantity,
        COALESCE(i.reorder_point, i.low_stock_qty) AS reorder_point,
        i.reorder_quantity,
        GREATEST(COALESCE(i.reorder_point, i.low_stock_qty) - i.quantity, 0) AS deficit,
        CASE WHEN i.quantity <= 0 THEN 'critical' ELSE 'warning' END AS urgency,
        c.name AS category,
        l.name AS location,
        i.unit_cost,
        NULL::text AS supplier,
        NULL::timestamptz AS last_reorder_date
    FROM public.inventory_items i
    LEFT JOIN public.inventory_categories c ON c.id = i.category_id AND c.deleted_at IS NULL
    LEFT JOIN public.inventory_locations l ON l.id = i.location_id AND l.deleted_at IS NULL
    WHERE i.company_id = v_company_id
      AND i.deleted_at IS NULL
      AND COALESCE(i.reorder_point, i.low_stock_qty) IS NOT NULL
      AND i.quantity <= COALESCE(i.reorder_point, i.low_stock_qty)
      AND (p_include_zero OR i.quantity > 0)
      AND (p_category IS NULL OR c.name ILIKE ('%' || p_category || '%'))
      AND (p_location IS NULL OR l.name ILIKE ('%' || p_location || '%'))
      AND (
        p_urgency IS NULL
        OR p_urgency = 'all'
        OR (p_urgency = 'critical' AND i.quantity <= 0)
        OR (p_urgency = 'warning' AND i.quantity > 0)
      )
    ORDER BY
        CASE WHEN i.quantity <= 0 THEN 0 ELSE 1 END,
        (COALESCE(i.reorder_point, i.low_stock_qty) - i.quantity) DESC,
        i.name
    LIMIT v_limit OFFSET v_offset;
END;
$$;

-- Orders RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Users can view active orders" ON public.orders;
CREATE POLICY "Users can view active orders"
    ON public.orders FOR SELECT
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:view')
        AND deleted_at IS NULL
    );

DROP POLICY IF EXISTS "Admins can view deleted orders" ON public.orders;
CREATE POLICY "Admins can view deleted orders"
    ON public.orders FOR SELECT
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:delete')
        AND deleted_at IS NOT NULL
    );

DROP POLICY IF EXISTS "Writers can create orders" ON public.orders;
CREATE POLICY "Writers can create orders"
    ON public.orders FOR INSERT
    WITH CHECK (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:create')
        AND deleted_at IS NULL
    );

DROP POLICY IF EXISTS "Writers can update orders" ON public.orders;
CREATE POLICY "Writers can update orders"
    ON public.orders FOR UPDATE
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:edit')
        AND deleted_at IS NULL
    )
    WITH CHECK (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:edit')
        AND deleted_at IS NULL
    );

-- Order recipients RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Users can view company recipients" ON public.order_recipients;
CREATE POLICY "Users can view company recipients"
    ON public.order_recipients FOR SELECT
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:view')
    );

DROP POLICY IF EXISTS "Writers can create recipients" ON public.order_recipients;
CREATE POLICY "Writers can create recipients"
    ON public.order_recipients FOR INSERT
    WITH CHECK (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:create')
    );

DROP POLICY IF EXISTS "Writers can update recipients" ON public.order_recipients;
CREATE POLICY "Writers can update recipients"
    ON public.order_recipients FOR UPDATE
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:edit')
    );

-- Order delete/restore RPCs: tier + permission enforcement
CREATE OR REPLACE FUNCTION public.soft_delete_order(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    -- Get company and verify order exists and is active
    SELECT company_id INTO v_company_id
    FROM public.orders
    WHERE id = p_order_id AND deleted_at IS NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Order not found');
    END IF;

    IF NOT public.has_tier_access(v_company_id, 'business') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(v_company_id, 'orders:delete') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    -- Soft delete with company guard
    UPDATE public.orders
    SET deleted_at = now(), deleted_by = auth.uid()
    WHERE id = p_order_id
    AND company_id = v_company_id;

    -- Log to action_metrics as DELETE
    INSERT INTO public.action_metrics (
        company_id, user_id, metric_date, action_type, table_name,
        action_count, records_affected
    ) VALUES (
        v_company_id, auth.uid(), CURRENT_DATE, 'delete', 'orders',
        1, 1
    )
    ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
    DO UPDATE SET
        action_count = action_metrics.action_count + 1,
        records_affected = action_metrics.records_affected + 1;

    RETURN json_build_object('success', true, 'message', 'Order moved to trash');
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_order(p_order_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    SELECT company_id INTO v_company_id
    FROM public.orders
    WHERE id = p_order_id AND deleted_at IS NOT NULL;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', 'Deleted order not found');
    END IF;

    IF NOT public.has_tier_access(v_company_id, 'business') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(v_company_id, 'orders:restore') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    UPDATE public.orders
    SET deleted_at = NULL, deleted_by = NULL
    WHERE id = p_order_id
    AND company_id = v_company_id;

    -- Log to audit
    INSERT INTO public.audit_log (action, table_name, record_id, company_id, user_id, new_values)
    VALUES ('RESTORE', 'orders', p_order_id, v_company_id, auth.uid(),
        jsonb_build_object('restored_at', now()));

    -- Log to action_metrics as RESTORE
    INSERT INTO public.action_metrics (
        company_id, user_id, metric_date, action_type, table_name,
        action_count, records_affected
    ) VALUES (
        v_company_id, auth.uid(), CURRENT_DATE, 'restore', 'orders',
        1, 1
    )
    ON CONFLICT (company_id, user_id, metric_date, action_type, table_name)
    DO UPDATE SET
        action_count = action_metrics.action_count + 1,
        records_affected = action_metrics.records_affected + 1;

    RETURN json_build_object('success', true, 'message', 'Order restored');
END;
$$;

-- Company-managed shipping addresses policies
DROP POLICY IF EXISTS "Users can view shipping addresses" ON public.company_shipping_addresses;
CREATE POLICY "Users can view shipping addresses"
    ON public.company_shipping_addresses FOR SELECT
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:view')
    );

DROP POLICY IF EXISTS "Managers can insert shipping addresses" ON public.company_shipping_addresses;
CREATE POLICY "Managers can insert shipping addresses"
    ON public.company_shipping_addresses FOR INSERT
    WITH CHECK (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

DROP POLICY IF EXISTS "Managers can update shipping addresses" ON public.company_shipping_addresses;
CREATE POLICY "Managers can update shipping addresses"
    ON public.company_shipping_addresses FOR UPDATE
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:manage_shipping')
    )
    WITH CHECK (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

DROP POLICY IF EXISTS "Managers can delete shipping addresses" ON public.company_shipping_addresses;
CREATE POLICY "Managers can delete shipping addresses"
    ON public.company_shipping_addresses FOR DELETE
    USING (
        public.has_tier_access(company_id, 'business')
        AND public.check_permission(company_id, 'orders:manage_shipping')
    );

-- Inventory import/export RPCs
CREATE OR REPLACE FUNCTION public.bulk_upsert_inventory_items(
    p_company_id UUID,
    p_items JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_inserted INTEGER := 0;
    v_updated INTEGER := 0;
BEGIN
    IF p_company_id IS NULL THEN
        RETURN json_build_object('success', false, 'error', 'Missing company_id');
    END IF;

    IF NOT public.has_tier_access(p_company_id, 'professional') THEN
        RETURN json_build_object('success', false, 'error', 'Feature not available for current plan');
    END IF;

    IF NOT public.check_permission(p_company_id, 'items:import') THEN
        RETURN json_build_object('success', false, 'error', 'Permission denied');
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
        RETURN json_build_object('success', false, 'error', 'Invalid items payload');
    END IF;

    WITH raw AS (
        SELECT
            NULLIF(trim(value->>'name'), '') AS name,
            trim(COALESCE(value->>'desc', value->>'description', '')) AS description,
            CASE
                WHEN (value->>'qty') ~ '^-?\\d+$' THEN (value->>'qty')::int
                ELSE 0
            END AS quantity
        FROM jsonb_array_elements(p_items) value
    ),
    cleaned AS (
        SELECT DISTINCT ON (lower(name))
            name,
            description,
            quantity
        FROM raw
        WHERE name IS NOT NULL
        ORDER BY lower(name)
    ),
    existing AS (
        SELECT id, name, description
        FROM public.inventory_items
        WHERE company_id = p_company_id AND deleted_at IS NULL
    ),
    to_insert AS (
        SELECT c.name, c.description, c.quantity
        FROM cleaned c
        LEFT JOIN existing e ON lower(e.name) = lower(c.name)
        WHERE e.id IS NULL
    ),
    to_update AS (
        SELECT e.id, c.name,
            CASE WHEN c.description = '' THEN e.description ELSE c.description END AS description,
            c.quantity
        FROM cleaned c
        JOIN existing e ON lower(e.name) = lower(c.name)
    ),
    ins AS (
        INSERT INTO public.inventory_items (
            company_id, name, description, quantity, reorder_enabled, created_by
        )
        SELECT p_company_id, name, description, quantity, true, auth.uid()
        FROM to_insert
        RETURNING id
    ),
    upd AS (
        UPDATE public.inventory_items i
        SET name = u.name,
            description = u.description,
            quantity = u.quantity
        FROM to_update u
        WHERE i.id = u.id
        RETURNING i.id
    )
    SELECT
        (SELECT COUNT(*) FROM ins),
        (SELECT COUNT(*) FROM upd)
    INTO v_inserted, v_updated;

    RETURN json_build_object(
        'success', true,
        'inserted', v_inserted,
        'updated', v_updated,
        'total', v_inserted + v_updated
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.export_inventory_items(p_company_id UUID)
RETURNS TABLE (id UUID, name TEXT, description TEXT, quantity INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
BEGIN
    IF p_company_id IS NULL THEN
        RETURN;
    END IF;

    IF NOT public.has_tier_access(p_company_id, 'professional') THEN
        RETURN;
    END IF;

    IF NOT public.check_permission(p_company_id, 'items:export') THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT i.id, i.name, i.description, i.quantity
    FROM public.inventory_items i
    WHERE i.company_id = p_company_id AND i.deleted_at IS NULL
    ORDER BY i.name ASC;
END;
$$;

COMMIT;
