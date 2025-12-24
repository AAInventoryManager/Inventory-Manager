-- Phase 1 remediation: role & access control entitlements
-- Feature IDs: inventory.auth.roles, inventory.auth.company_membership, inventory.auth.user_management,
--              inventory.auth.invite_users, inventory.auth.role_requests

-- Company members RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Users can view company members" ON public.company_members;
CREATE POLICY "Users can view company members"
    ON public.company_members FOR SELECT
    USING (
        user_id = auth.uid()
        OR (
            public.get_company_tier(company_id) IN ('business','enterprise')
            AND public.check_permission(company_id, 'members:view')
        )
    );

DROP POLICY IF EXISTS "Admins can add members" ON public.company_members;
CREATE POLICY "Admins can add members"
    ON public.company_members FOR INSERT
    WITH CHECK (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'members:invite')
        AND is_super_user = false
    );

DROP POLICY IF EXISTS "Admins can update member roles" ON public.company_members;
CREATE POLICY "Admins can update member roles"
    ON public.company_members FOR UPDATE
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'members:change_role')
    )
    WITH CHECK (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'members:change_role')
        AND is_super_user = false
    );

-- Invitations RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Admins can view invitations" ON public.invitations;
CREATE POLICY "Admins can view invitations"
    ON public.invitations FOR SELECT
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'members:invite')
    );

DROP POLICY IF EXISTS "Admins can create invitations" ON public.invitations;
CREATE POLICY "Admins can create invitations"
    ON public.invitations FOR INSERT
    WITH CHECK (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'members:invite')
    );

DROP POLICY IF EXISTS "Admins can update invitations" ON public.invitations;
CREATE POLICY "Admins can update invitations"
    ON public.invitations FOR UPDATE
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
        AND public.check_permission(company_id, 'members:invite')
    );

-- Role change requests RLS: tier + permission enforcement
DROP POLICY IF EXISTS "Users can view own requests" ON public.role_change_requests;
CREATE POLICY "Users can view own requests"
    ON public.role_change_requests FOR SELECT
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
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
        AND public.get_company_tier(company_id) IN ('business','enterprise')
    );

DROP POLICY IF EXISTS "Admins can update requests" ON public.role_change_requests;
CREATE POLICY "Admins can update requests"
    ON public.role_change_requests FOR UPDATE
    USING (
        public.get_company_tier(company_id) IN ('business','enterprise')
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
    IF public.get_company_tier(p_company_id) NOT IN ('business','enterprise') THEN
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

    IF public.get_company_tier(v_invitation.company_id) NOT IN ('business','enterprise') THEN
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

    IF public.get_company_tier(v_company_id) NOT IN ('business','enterprise') THEN
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

    IF public.get_company_tier(v_request.company_id) NOT IN ('business','enterprise') THEN
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

    IF public.get_company_tier(v_company_id) NOT IN ('business','enterprise') THEN
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
