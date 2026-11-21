-- Allow an administrator to explicitly override an overlapping booking.
-- An override requires a non-empty reason and is recorded in audit_logs.
-- Applied to the test Supabase project only; no production changes.

CREATE OR REPLACE FUNCTION public.allocate_assistant(
  p_case_id uuid,
  p_assistant_id uuid,
  p_override_warnings boolean DEFAULT false,
  p_override_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_case public.surgical_cases%rowtype;
  v_assistant public.assistants%rowtype;
  v_availability_match boolean;
  v_explicitly_unavailable boolean;
  v_platform_match boolean;
  v_conflict boolean;
  v_invitation_id uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Administrator access required';
  END IF;

  SELECT * INTO v_case FROM public.surgical_cases WHERE id = p_case_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Surgical case not found'; END IF;
  IF v_case.status <> 'unmatched' THEN RAISE EXCEPTION 'Case is not available for allocation'; END IF;

  SELECT * INTO v_assistant FROM public.assistants
  WHERE id = p_assistant_id AND active = true FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Active assistant not found'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.surgical_cases c
    WHERE c.assistant_id = p_assistant_id AND c.id <> p_case_id
      AND c.case_date = v_case.case_date
      AND c.status IN ('invited', 'confirmed')
      AND c.start_time < v_case.finish_time AND c.finish_time > v_case.start_time
  ) INTO v_conflict;

  SELECT EXISTS (
    SELECT 1 FROM public.availability av
    WHERE av.assistant_id = p_assistant_id
      AND av.availability_date = v_case.case_date
      AND av.availability_type = 'unavailable'
  ) INTO v_explicitly_unavailable;

  SELECT (
    NOT v_explicitly_unavailable AND EXISTS (
      SELECT 1 FROM public.availability av
      WHERE av.assistant_id = p_assistant_id
        AND av.availability_date = v_case.case_date
        AND (av.availability_type = 'full_day' OR (
          av.availability_type = 'specific_hours'
          AND av.start_time <= v_case.start_time AND av.finish_time >= v_case.finish_time
        ))
    )
  ) INTO v_availability_match;

  v_platform_match := true;

  IF (v_conflict OR NOT v_availability_match)
     AND p_override_warnings IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Warning: booking overlap or availability warning detected. Explicit administrator acknowledgement is required to proceed.';
  END IF;

  IF (v_conflict OR NOT v_availability_match)
     AND NULLIF(TRIM(p_override_reason), '') IS NULL THEN
    RAISE EXCEPTION 'An explanation is required when overriding booking or availability warnings.';
  END IF;

  INSERT INTO public.invitations (case_id, assistant_id, status)
  VALUES (p_case_id, p_assistant_id, 'pending') RETURNING id INTO v_invitation_id;

  UPDATE public.surgical_cases
  SET assistant_id = p_assistant_id, status = 'invited', updated_at = now()
  WHERE id = p_case_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'assistant_invited', 'surgical_case', p_case_id,
    jsonb_build_object(
      'assistant_id', p_assistant_id,
      'availability_match', v_availability_match,
      'availability_submitted', EXISTS (
        SELECT 1 FROM public.availability av
        WHERE av.assistant_id = p_assistant_id AND av.availability_date = v_case.case_date
      ),
      'explicitly_unavailable', v_explicitly_unavailable,
      'booking_conflict', v_conflict,
      'booking_conflict_override', v_conflict AND p_override_warnings,
      'platform_match', v_platform_match,
      'availability_override', NOT v_availability_match,
      'platform_override', NOT v_platform_match,
      'override_reason', p_override_reason
    )
  );
  RETURN v_invitation_id;
END;
$function$;
