-- Invite lifecycle RPCs for ephemeral invites + durable analytics
-- Feature IDs: inventory.auth.invite_lifecycle

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

SET search_path TO public, extensions;

-- Helper: deterministic, one-way email hash for analytics (no PII).
CREATE OR REPLACE FUNCTION public.hash_invite_email(p_email TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SET search_path = public, extensions
AS $$
    SELECT CASE
        WHEN p_email IS NULL THEN NULL
        ELSE encode(digest(lower(trim(p_email))::bytea, 'sha256'), 'hex')
    END;
$$;

-- Send a new company invite (pending only).
CREATE OR REPLACE FUNCTION public.send_company_invite(
    p_company_id UUID,
    p_email TEXT,
    p_role TEXT,
    p_expires_at TIMESTAMPTZ
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_email TEXT;
    v_invite_id UUID;
    v_now TIMESTAMPTZ := now();
BEGIN
    IF p_company_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Company is required');
    END IF;

    v_email := lower(trim(COALESCE(p_email, '')));
    IF v_email = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Email is required');
    END IF;

    IF p_role IS NULL OR p_role NOT IN ('admin', 'member', 'viewer') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid role');
    END IF;

    IF p_expires_at IS NULL OR p_expires_at <= v_now THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid expiration');
    END IF;

    IF NOT public.user_can_invite(p_company_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Permission denied');
    END IF;

    INSERT INTO public.company_invites (
        company_id,
        email,
        role,
        invited_by_user_id,
        sent_at,
        last_sent_at,
        resend_count,
        expires_at,
        status
    ) VALUES (
        p_company_id,
        v_email,
        p_role,
        auth.uid(),
        v_now,
        v_now,
        0,
        p_expires_at,
        'pending'
    )
    ON CONFLICT (company_id, email) WHERE status = 'pending'
    DO NOTHING
    RETURNING id INTO v_invite_id;

    IF v_invite_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Pending invite already exists');
    END IF;

    INSERT INTO public.invite_events (
        event_type,
        company_id,
        invite_email_hash,
        invited_by_user_id,
        resend_count,
        occurred_at
    ) VALUES (
        'invite_sent',
        p_company_id,
        public.hash_invite_email(v_email),
        auth.uid(),
        0,
        v_now
    );

    RETURN jsonb_build_object(
        'success', true,
        'invite_id', v_invite_id,
        'status', 'pending',
        'expires_at', p_expires_at
    );
END;
$$;

-- Resend an existing pending invite.
CREATE OR REPLACE FUNCTION public.resend_company_invite(p_invite_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_invite RECORD;
    v_resend_count INTEGER;
    v_last_sent_at TIMESTAMPTZ;
    v_now TIMESTAMPTZ := now();
BEGIN
    IF p_invite_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite id is required');
    END IF;

    SELECT *
    INTO v_invite
    FROM public.company_invites
    WHERE id = p_invite_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite not found');
    END IF;

    IF v_invite.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite is not pending');
    END IF;

    IF v_invite.expires_at <= v_now THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite has expired');
    END IF;

    IF NOT public.user_can_invite(v_invite.company_id) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Permission denied');
    END IF;

    UPDATE public.company_invites
    SET last_sent_at = v_now,
        resend_count = resend_count + 1
    WHERE id = p_invite_id
      AND status = 'pending'
    RETURNING resend_count, last_sent_at
    INTO v_resend_count, v_last_sent_at;

    IF v_resend_count IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite is not pending');
    END IF;

    INSERT INTO public.invite_events (
        event_type,
        company_id,
        invite_email_hash,
        invited_by_user_id,
        resend_count,
        occurred_at
    ) VALUES (
        'invite_resent',
        v_invite.company_id,
        public.hash_invite_email(v_invite.email),
        auth.uid(),
        v_resend_count,
        v_now
    );

    RETURN jsonb_build_object(
        'success', true,
        'invite_id', p_invite_id,
        'resend_count', v_resend_count,
        'last_sent_at', v_last_sent_at
    );
END;
$$;

-- Accept a pending invite and create membership; delete invite row afterward.
CREATE OR REPLACE FUNCTION public.accept_company_invite(p_invite_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_invite RECORD;
    v_user_id UUID;
    v_existing_company UUID;
    v_admin_id UUID;
    v_latency_seconds INTEGER;
    v_now TIMESTAMPTZ := now();
    v_invite_email TEXT;
    v_auth_email TEXT;
    v_instance_id UUID;
BEGIN
    IF p_invite_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite id is required');
    END IF;

    SELECT id, company_id, email, role, invited_by_user_id, sent_at, expires_at, status
    INTO v_invite
    FROM public.company_invites
    WHERE id = p_invite_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite not found');
    END IF;

    v_invite_email := lower(trim(v_invite.email));

    IF v_invite.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite is not pending');
    END IF;

    IF v_invite.expires_at <= v_now THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invite has expired');
    END IF;

    IF auth.uid() IS NOT NULL THEN
        v_user_id := auth.uid();
        SELECT lower(trim(email))
        INTO v_auth_email
        FROM auth.users
        WHERE id = v_user_id;

        IF v_auth_email IS NULL OR v_auth_email <> v_invite_email THEN
            RETURN jsonb_build_object('success', false, 'error', 'Invitation was sent to a different email');
        END IF;
    ELSE
        SELECT id
        INTO v_user_id
        FROM auth.users
        WHERE lower(trim(email)) = v_invite_email
        LIMIT 1;
    END IF;

    IF v_user_id IS NULL THEN
        SELECT id INTO v_instance_id FROM auth.instances LIMIT 1;

        BEGIN
            INSERT INTO auth.users (
                instance_id,
                aud,
                role,
                email,
                encrypted_password,
                email_confirmed_at,
                raw_app_meta_data,
                raw_user_meta_data,
                created_at,
                updated_at
            ) VALUES (
                v_instance_id,
                'authenticated',
                'authenticated',
                v_invite_email,
                crypt(gen_random_uuid()::text, gen_salt('bf')),
                v_now,
                jsonb_build_object('provider', 'email', 'providers', ARRAY['email']),
                '{}'::jsonb,
                v_now,
                v_now
            )
            ON CONFLICT DO NOTHING
            RETURNING id INTO v_user_id;
        EXCEPTION
            WHEN undefined_column THEN
                INSERT INTO auth.users (email)
                VALUES (v_invite_email)
                ON CONFLICT DO NOTHING
                RETURNING id INTO v_user_id;
        END;

        IF v_user_id IS NULL THEN
            SELECT id
            INTO v_user_id
            FROM auth.users
            WHERE lower(trim(email)) = v_invite_email
            LIMIT 1;
        END IF;

        IF v_user_id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'Failed to create user');
        END IF;

        BEGIN
            INSERT INTO auth.identities (
                id,
                user_id,
                identity_data,
                provider,
                provider_id,
                last_sign_in_at,
                created_at,
                updated_at
            ) VALUES (
                gen_random_uuid(),
                v_user_id,
                jsonb_build_object('sub', v_user_id::text, 'email', v_invite_email),
                'email',
                v_invite_email,
                v_now,
                v_now,
                v_now
            )
            ON CONFLICT DO NOTHING;
        EXCEPTION
            WHEN undefined_column THEN
                INSERT INTO auth.identities (
                    id,
                    user_id,
                    identity_data,
                    provider,
                    last_sign_in_at,
                    created_at,
                    updated_at
                ) VALUES (
                    gen_random_uuid(),
                    v_user_id,
                    jsonb_build_object('sub', v_user_id::text, 'email', v_invite_email),
                    'email',
                    v_now,
                    v_now,
                    v_now
                )
                ON CONFLICT DO NOTHING;
        END;
    END IF;

    SELECT company_id
    INTO v_existing_company
    FROM public.company_members
    WHERE user_id = v_user_id;

    IF v_existing_company IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'User is already a member of a company');
    END IF;

    SELECT user_id
    INTO v_admin_id
    FROM public.company_members
    WHERE company_id = v_invite.company_id
      AND role = 'admin'
    LIMIT 1;

    INSERT INTO public.company_members (
        company_id,
        user_id,
        role,
        invited_by,
        assigned_admin_id
    ) VALUES (
        v_invite.company_id,
        v_user_id,
        v_invite.role,
        v_invite.invited_by_user_id,
        COALESCE(v_admin_id, v_invite.invited_by_user_id)
    );

    v_latency_seconds := GREATEST(0, EXTRACT(EPOCH FROM (v_now - v_invite.sent_at))::INTEGER);

    INSERT INTO public.invite_events (
        event_type,
        company_id,
        invite_email_hash,
        invited_by_user_id,
        latency_seconds,
        occurred_at
    ) VALUES (
        'invite_accepted',
        v_invite.company_id,
        public.hash_invite_email(v_invite_email),
        v_invite.invited_by_user_id,
        v_latency_seconds,
        v_now
    );

    DELETE FROM public.company_invites
    WHERE id = v_invite.id;

    RETURN jsonb_build_object(
        'success', true,
        'company_id', v_invite.company_id,
        'user_id', v_user_id,
        'role', v_invite.role
    );
END;
$$;

-- Expire pending invites and emit analytics events.
CREATE OR REPLACE FUNCTION public.expire_company_invites()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
    v_expired_count INTEGER := 0;
BEGIN
    WITH expired AS (
        UPDATE public.company_invites
        SET status = 'expired'
        WHERE status = 'pending'
          AND expires_at < now()
        RETURNING company_id, email, invited_by_user_id, resend_count
    ),
    inserted AS (
        INSERT INTO public.invite_events (
            event_type,
            company_id,
            invite_email_hash,
            invited_by_user_id,
            resend_count,
            occurred_at
        )
        SELECT
            'invite_expired',
            company_id,
            public.hash_invite_email(email),
            invited_by_user_id,
            resend_count,
            now()
        FROM expired
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_expired_count FROM inserted;

    RETURN v_expired_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.hash_invite_email(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_company_invite(UUID, TEXT, TEXT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resend_company_invite(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_company_invite(UUID) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.expire_company_invites() TO service_role;

COMMIT;
