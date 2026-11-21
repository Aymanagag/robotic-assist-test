alter table public.surgical_cases
  drop constraint if exists surgical_cases_status_check;

alter table public.surgical_cases
  add constraint surgical_cases_status_check
  check (status = any (array['unmatched','invited','confirmed','cancelled','completed']::text[]));

alter table public.surgical_cases
  add column if not exists completed_at timestamptz,
  add column if not exists completed_by uuid references public.profiles(id);

create or replace function public.complete_surgical_case(p_case_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_case public.surgical_cases%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required.';
  end if;

  select * into v_case from public.surgical_cases where id = p_case_id for update;
  if not found then raise exception 'Case not found.'; end if;
  if v_case.status <> 'confirmed' then
    raise exception 'Only confirmed cases can be marked as completed.';
  end if;

  update public.surgical_cases
  set status = 'completed', completed_at = now(), completed_by = auth.uid(), updated_at = now()
  where id = p_case_id;

  insert into public.audit_logs(actor_id, action, entity_type, entity_id, details)
  values (auth.uid(), 'case_completed', 'surgical_case', p_case_id,
    jsonb_build_object('previous_status', v_case.status, 'assistant_id', v_case.assistant_id));
end;
$function$;

revoke all on function public.complete_surgical_case(uuid) from public, anon;
grant execute on function public.complete_surgical_case(uuid) to authenticated;
