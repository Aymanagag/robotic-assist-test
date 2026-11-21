alter table public.profiles add column if not exists is_active boolean not null default true;

create or replace function public.is_active_user()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.profiles p where p.id=(select auth.uid()) and p.is_active=true); $$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.profiles p where p.id=(select auth.uid()) and p.role='admin' and p.is_active=true); $$;

revoke all on function public.is_active_user() from public, anon;
grant execute on function public.is_active_user() to authenticated;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

create or replace function public.admin_set_user_role(p_user_id uuid,p_new_role text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := (select auth.uid()); v_old_role text; v_name text; v_is_active boolean;
begin
 if v_actor is null or not public.is_admin() then raise exception 'Active administrator access required'; end if;
 if p_user_id is null or p_new_role not in ('admin','assistant') then raise exception 'Invalid user or role'; end if;
 if p_user_id=v_actor then raise exception 'You cannot change your own administrator role'; end if;
 perform pg_advisory_xact_lock(hashtextextended('robotic_assist_user_admin',0));
 select role,full_name,is_active into v_old_role,v_name,v_is_active from public.profiles where id=p_user_id for update;
 if not found then raise exception 'User not found'; end if;
 if v_old_role=p_new_role then return; end if;
 if v_old_role='admin' and p_new_role='assistant' and
   (select count(*) from public.profiles where role='admin' and is_active=true)<=1 then
   raise exception 'The last active administrator cannot be demoted';
 end if;
 update public.profiles set role=p_new_role where id=p_user_id;
 if p_new_role='assistant' then
   insert into public.assistants(profile_id,active) values(p_user_id,v_is_active)
   on conflict(profile_id) do update set active=excluded.active;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(v_actor,'user_role_changed','profile',p_user_id,jsonb_build_object('full_name',v_name,'previous_role',v_old_role,'new_role',p_new_role));
end; $$;

create or replace function public.admin_set_user_active(p_user_id uuid,p_is_active boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_actor uuid := (select auth.uid()); v_role text; v_old_active boolean; v_name text;
begin
 if v_actor is null or not public.is_admin() then raise exception 'Active administrator access required'; end if;
 if p_user_id is null or p_is_active is null then raise exception 'Invalid user or account status'; end if;
 if p_user_id=v_actor then raise exception 'You cannot deactivate your own account'; end if;
 perform pg_advisory_xact_lock(hashtextextended('robotic_assist_user_admin',0));
 select role,is_active,full_name into v_role,v_old_active,v_name from public.profiles where id=p_user_id for update;
 if not found then raise exception 'User not found'; end if;
 if v_old_active=p_is_active then return; end if;
 if v_role='admin' and p_is_active=false and
   (select count(*) from public.profiles where role='admin' and is_active=true)<=1 then
   raise exception 'The last active administrator cannot be deactivated';
 end if;
 update public.profiles set is_active=p_is_active where id=p_user_id;
 update public.assistants set active=p_is_active where profile_id=p_user_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values(v_actor,case when p_is_active then 'user_reactivated' else 'user_deactivated' end,'profile',p_user_id,
 jsonb_build_object('full_name',v_name,'role',v_role,'previous_is_active',v_old_active,'is_active',p_is_active));
end; $$;

revoke all on function public.admin_set_user_role(uuid,text) from public,anon;
grant execute on function public.admin_set_user_role(uuid,text) to authenticated;
revoke all on function public.admin_set_user_active(uuid,boolean) from public,anon;
grant execute on function public.admin_set_user_active(uuid,boolean) to authenticated;

drop policy if exists "Users view own profile" on public.profiles;
create policy "Users view own active profile" on public.profiles for select to authenticated
using(id=(select auth.uid()) and is_active=true);

drop policy if exists "Assistants view own record" on public.assistants;
create policy "Active assistants view own record" on public.assistants for select to authenticated
using(profile_id=(select auth.uid()) and active=true and (select public.is_active_user()));

drop policy if exists "Assistants view own availability" on public.availability;
create policy "Active assistants view own availability" on public.availability for select to authenticated
using((select public.is_active_user()) and exists(select 1 from public.assistants a where a.id=availability.assistant_id and a.profile_id=(select auth.uid()) and a.active=true));
drop policy if exists "Assistants submit own availability" on public.availability;
create policy "Active assistants submit own availability" on public.availability for insert to authenticated
with check((select public.is_active_user()) and exists(select 1 from public.assistants a where a.id=availability.assistant_id and a.profile_id=(select auth.uid()) and a.active=true));
drop policy if exists "Assistants update own availability" on public.availability;
create policy "Active assistants update own availability" on public.availability for update to authenticated
using((select public.is_active_user()) and exists(select 1 from public.assistants a where a.id=availability.assistant_id and a.profile_id=(select auth.uid()) and a.active=true))
with check((select public.is_active_user()) and exists(select 1 from public.assistants a where a.id=availability.assistant_id and a.profile_id=(select auth.uid()) and a.active=true));
drop policy if exists "Assistants delete own availability" on public.availability;
create policy "Active assistants delete own availability" on public.availability for delete to authenticated
using((select public.is_active_user()) and exists(select 1 from public.assistants a where a.id=availability.assistant_id and a.profile_id=(select auth.uid()) and a.active=true));

drop policy if exists "Assistants view own invitations" on public.invitations;
create policy "Active assistants view own invitations" on public.invitations for select to authenticated
using((select public.is_active_user()) and exists(select 1 from public.assistants a where a.id=invitations.assistant_id and a.profile_id=(select auth.uid()) and a.active=true));
drop policy if exists "Assistants view assigned cases" on public.surgical_cases;
create policy "Active assistants view assigned cases" on public.surgical_cases for select to authenticated
using((select public.is_active_user()) and exists(select 1 from public.assistants a where a.id=surgical_cases.assistant_id and a.profile_id=(select auth.uid()) and a.active=true));

drop policy if exists "Authenticated view hospitals" on public.hospitals;
create policy "Active users view hospitals" on public.hospitals for select to authenticated using((select public.is_active_user()));
drop policy if exists "Authenticated view procedures" on public.procedures;
create policy "Active users view procedures" on public.procedures for select to authenticated using((select public.is_active_user()));
drop policy if exists "Authenticated view surgeons" on public.surgeons;
create policy "Active users view surgeons" on public.surgeons for select to authenticated using((select public.is_active_user()));

drop policy if exists "Users view own notifications" on public.notifications;
create policy "Active users view own notifications" on public.notifications for select to authenticated
using(recipient_id=(select auth.uid()) and (select public.is_active_user()));
drop policy if exists "Users mark own notifications read" on public.notifications;
create policy "Active users mark own notifications read" on public.notifications for update to authenticated
using(recipient_id=(select auth.uid()) and (select public.is_active_user()))
with check(recipient_id=(select auth.uid()) and (select public.is_active_user()));

create or replace function public.respond_to_invitation(p_invitation_id uuid,p_response text,p_response_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_invitation public.invitations%rowtype; v_case public.surgical_cases%rowtype; v_assistant public.assistants%rowtype;
begin
 if (select auth.uid()) is null or not public.is_active_user() then raise exception 'Active assistant access required'; end if;
 if p_response not in ('accepted','declined') then raise exception 'Invalid invitation response'; end if;
 select * into v_invitation from public.invitations where id=p_invitation_id;
 if not found then raise exception 'Invitation not found'; end if;
 select * into v_case from public.surgical_cases where id=v_invitation.case_id for update;
 if not found then raise exception 'Surgical case not found'; end if;
 select * into v_assistant from public.assistants where id=v_invitation.assistant_id for update;
 if not found or v_assistant.active is distinct from true then raise exception 'Active assistant not found'; end if;
 if v_assistant.profile_id is distinct from (select auth.uid()) then raise exception 'You cannot respond to another assistant invitation'; end if;
 select * into v_invitation from public.invitations where id=p_invitation_id for update;
 if v_invitation.status<>'pending' then raise exception 'This invitation has already been answered'; end if;
 if v_case.status<>'invited' or v_case.assistant_id<>v_assistant.id then raise exception 'This invitation is no longer active'; end if;
 if p_response='accepted' and exists(select 1 from public.surgical_cases c where c.assistant_id=v_assistant.id and c.id<>v_case.id and c.case_date=v_case.case_date and c.status in ('invited','confirmed') and c.start_time<v_case.finish_time and c.finish_time>v_case.start_time) then raise exception 'Booking conflict: acceptance blocked'; end if;
 update public.invitations set status=p_response,responded_at=now(),response_note=p_response_note where id=p_invitation_id;
 if p_response='accepted' then update public.surgical_cases set status='confirmed',updated_at=now() where id=v_case.id;
 else update public.surgical_cases set status='unmatched',assistant_id=null,updated_at=now() where id=v_case.id; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
 values((select auth.uid()),'invitation_'||p_response,'surgical_case',v_case.id,jsonb_build_object('invitation_id',p_invitation_id,'assistant_id',v_assistant.id,'response_note',p_response_note));
end; $$;
