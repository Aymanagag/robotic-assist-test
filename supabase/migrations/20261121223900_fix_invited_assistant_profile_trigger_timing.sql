-- Supabase may populate invited_at after inserting auth.users. Listen for that
-- transition as well as initial inserts, then backfill existing invitations.
create or replace function private.handle_new_assistant_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_name text;
begin
  if new.invited_at is not null then
    v_name := coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Assistant'
    );

    insert into public.profiles (id, full_name, email, role)
    values (new.id, v_name, new.email, 'assistant')
    on conflict (id) do update
      set email = excluded.email;

    insert into public.assistants (profile_id, active)
    values (new.id, true)
    on conflict (profile_id) do nothing;
  end if;
  return new;
end;
$function$;

drop trigger if exists on_auth_user_created_assistant_profile on auth.users;
create trigger on_auth_user_created_assistant_profile
after insert or update of invited_at on auth.users
for each row execute function private.handle_new_assistant_auth_user();

insert into public.profiles (id, full_name, email, role)
select
  u.id,
  coalesce(
    nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(u.raw_user_meta_data ->> 'name'), ''),
    nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
    'Assistant'
  ),
  u.email,
  'assistant'
from auth.users u
where u.invited_at is not null
on conflict (id) do update set email = excluded.email;

insert into public.assistants (profile_id, active)
select u.id, true
from auth.users u
where u.invited_at is not null
on conflict (profile_id) do nothing;
