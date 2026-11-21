-- Harden RPC and table privileges in the test Supabase project only.
-- Keep authenticated CRUD permissions and existing RLS policies unchanged.

REVOKE EXECUTE ON FUNCTION public.change_case_assistant(uuid, uuid, text, boolean, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.remove_case_assistant(uuid, text) FROM PUBLIC, anon;

REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLE
  public.assistants,
  public.audit_logs,
  public.availability,
  public.hospitals,
  public.invitations,
  public.procedures,
  public.profiles,
  public.surgeons,
  public.surgical_cases
FROM authenticated;
