-- Create application profiles only for users invited through Supabase Auth.
-- Public self-signups, if enabled at the Auth project level, do not gain app access.
create schema if not exists private;

create or replace function private.handle_new_assistant_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  if new.invited_at is null then
    return new;
  end if;

  v_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
    split_part(new.email, '@', 1)
  );

  insert into public.profiles (id, full_name, role)
  values (new.id, v_name, 'assistant')
  on conflict (id) do nothing;

  insert into public.assistants (profile_id, active)
  values (new.id, true)
  on conflict (profile_id) do nothing;

  return new;
end;
$$;

revoke all on function private.handle_new_assistant_auth_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_assistant_profile on auth.users;
create trigger on_auth_user_created_assistant_profile
  after insert on auth.users
  for each row execute function private.handle_new_assistant_auth_user();

comment on function private.handle_new_assistant_auth_user() is
  'Creates a least-privilege assistant profile and assistant record only for newly invited Auth users. Ignores user-supplied role metadata.';
