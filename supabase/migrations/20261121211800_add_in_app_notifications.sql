-- In-app notifications for assistants and administrators.
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  notification_type text not null,
  title text not null,
  message text not null,
  case_id uuid references public.surgical_cases(id) on delete set null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists notifications_recipient_created_idx
  on public.notifications (recipient_id, created_at desc);
create index if not exists notifications_case_id_idx
  on public.notifications (case_id);
alter table public.notifications enable row level security;
revoke all on public.notifications from anon;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

create policy "Users view own notifications" on public.notifications
for select to authenticated using (recipient_id = (select auth.uid()));
create policy "Users mark own notifications read" on public.notifications
for update to authenticated using (recipient_id = (select auth.uid()))
with check (recipient_id = (select auth.uid()));

create or replace function public.create_notification(
  p_recipient_id uuid, p_type text, p_title text, p_message text, p_case_id uuid
) returns void language sql security definer set search_path = '' as $$
  insert into public.notifications(recipient_id, notification_type, title, message, case_id)
  values (p_recipient_id, p_type, p_title, p_message, p_case_id);
$$;
revoke all on function public.create_notification(uuid,text,text,text,uuid) from public, anon, authenticated;

create or replace function public.notify_invitation_changes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_case public.surgical_cases%rowtype;
  v_assistant_profile uuid;
  v_admin record;
  v_title text;
  v_message text;
  v_type text;
begin
  select * into v_case from public.surgical_cases where id = coalesce(new.case_id, old.case_id);
  if not found then return coalesce(new, old); end if;
  if tg_op = 'INSERT' and new.status = 'pending' then
    select profile_id into v_assistant_profile from public.assistants where id = new.assistant_id;
    if v_assistant_profile is not null then
      perform public.create_notification(v_assistant_profile, 'new_invitation', 'New case invitation',
        'You have been invited to ' || coalesce((select name from public.procedures where id=v_case.procedure_id),'a procedure')
        || ' on ' || to_char(v_case.case_date,'DD Mon YYYY')
        || ' (' || to_char(v_case.start_time,'HH24:MI') || '–' || to_char(v_case.finish_time,'HH24:MI') || ').', v_case.id);
    end if;
  elsif tg_op = 'UPDATE' and old.status is distinct from new.status
        and new.status in ('accepted','declined','withdrawn') then
    v_type := 'invitation_' || new.status;
    v_title := case new.status when 'accepted' then 'Invitation accepted'
      when 'declined' then 'Invitation declined' else 'Invitation withdrawn' end;
    v_message := coalesce((select full_name from public.profiles p join public.assistants a on a.profile_id=p.id where a.id=new.assistant_id),'An assistant')
      || ' has ' || case new.status when 'accepted' then 'accepted' when 'declined' then 'declined' else 'had an invitation withdrawn for' end
      || ' ' || coalesce((select name from public.procedures where id=v_case.procedure_id),'the case')
      || ' on ' || to_char(v_case.case_date,'DD Mon YYYY') || '.';
    for v_admin in select id from public.profiles where role='admin' loop
      perform public.create_notification(v_admin.id, v_type, v_title, v_message, v_case.id);
    end loop;
    if new.status='withdrawn' then
      select profile_id into v_assistant_profile from public.assistants where id=new.assistant_id;
      if v_assistant_profile is not null then
        perform public.create_notification(v_assistant_profile, 'invitation_withdrawn', 'Case invitation withdrawn',
          'Your invitation for ' || coalesce((select name from public.procedures where id=v_case.procedure_id),'the case')
          || ' on ' || to_char(v_case.case_date,'DD Mon YYYY') || ' has been withdrawn.', v_case.id);
      end if;
    end if;
  end if;
  return coalesce(new, old);
end;
$$;
drop trigger if exists trg_notify_invitation_changes on public.invitations;
create trigger trg_notify_invitation_changes after insert or update of status on public.invitations
for each row execute function public.notify_invitation_changes();

create or replace function public.notify_case_timing_changes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_profile_id uuid;
begin
  if (old.case_date, old.start_time, old.finish_time) is distinct from (new.case_date, new.start_time, new.finish_time)
     and new.assistant_id is not null and new.status in ('invited','confirmed') then
    select profile_id into v_profile_id from public.assistants where id=new.assistant_id;
    if v_profile_id is not null then
      perform public.create_notification(v_profile_id, 'case_timing_changed', 'Case date or time changed',
        'The case has been rescheduled to ' || to_char(new.case_date,'DD Mon YYYY')
        || ' (' || to_char(new.start_time,'HH24:MI') || '–' || to_char(new.finish_time,'HH24:MI') || '). Please review the updated details.', new.id);
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_case_timing_changes on public.surgical_cases;
create trigger trg_notify_case_timing_changes after update of case_date, start_time, finish_time
on public.surgical_cases for each row execute function public.notify_case_timing_changes();

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime'
    and schemaname='public' and tablename='notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- Trigger functions are invoked by their table triggers, not through the Data API.
-- Revoke default PUBLIC execution so they cannot be called as SECURITY DEFINER RPCs.
revoke all on function public.notify_invitation_changes() from public, anon, authenticated;
revoke all on function public.notify_case_timing_changes() from public, anon, authenticated;
