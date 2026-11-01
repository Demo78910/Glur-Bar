CREATE SCHEMA IF NOT EXISTS glur_private;
CREATE TABLE IF NOT EXISTS public.glur_system_developers(
 user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.glur_system_developers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.glur_system_developers FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.glur_system_developers TO service_role;
INSERT INTO public.glur_system_developers(user_id)
 SELECT user_id FROM public.glur_usernames WHERE username IN ('owner001','owner002') ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION glur_private.is_developer(p_shop_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(
 SELECT 1 FROM public.glur_system_developers d JOIN public.glur_members m ON m.user_id=d.user_id
 WHERE d.user_id=auth.uid() AND (p_shop_id IS NULL OR m.shop_id=p_shop_id));
$$;
REVOKE ALL ON FUNCTION glur_private.is_developer(uuid) FROM PUBLIC,anon;
GRANT USAGE ON SCHEMA glur_private TO authenticated;
GRANT EXECUTE ON FUNCTION glur_private.is_developer(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.glur_is_developer(p_shop_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT glur_private.is_developer(p_shop_id); $$;
REVOKE ALL ON FUNCTION public.glur_is_developer(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_is_developer(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.glur_my_permissions(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.glur_members WHERE shop_id=p_shop_id AND user_id=auth.uid()) THEN RAISE EXCEPTION 'Not a shop member'; END IF;
 SELECT coalesce(jsonb_object_agg(permission_key,allowed),'{}'::jsonb) INTO result FROM public.glur_member_permissions WHERE shop_id=p_shop_id AND user_id=auth.uid();
 RETURN result || jsonb_build_object('system_developer',glur_private.is_developer(p_shop_id));
END $$;
-- Guard existing operational RPCs in place, preserving all validation and transactions.
DO $guard$
DECLARE f record; def text; guard text;
BEGIN
 FOR f IN SELECT oid,proname FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN(
 'glur_record_backdated_sale','glur_owner_reset_data','glur_reset_test_transactions',
 'glur_owner_clone_live_to_test','glur_owner_clone_preview','glur_owner_delete_daily_closing')
 LOOP
  def:=pg_get_functiondef(f.oid);
  IF position('GLUR_DEVELOPER_ONLY' IN def)=0 THEN
   guard:=' /* GLUR_DEVELOPER_ONLY */ IF NOT glur_private.is_developer('||CASE WHEN f.proname IN ('glur_owner_clone_live_to_test','glur_owner_clone_preview') THEN 'NULL' ELSE 'p_shop_id' END||') THEN RAISE EXCEPTION ''Developer only''; END IF; ';
   def:=regexp_replace(def,'\mBEGIN\M','BEGIN '||guard,'i');
   EXECUTE def;
  END IF;
 END LOOP;
END $guard$;
NOTIFY pgrst,'reload schema';
DO $guard$ DECLARE def text; BEGIN
SELECT pg_get_functiondef(oid) INTO def FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname='glur_employee_profile_set';
IF position('GLUR_PROTECT_DEVELOPER' IN def)=0 THEN
def:=regexp_replace(def,'BEGIN','BEGIN /* GLUR_PROTECT_DEVELOPER */ IF EXISTS(SELECT 1 FROM public.glur_system_developers WHERE user_id=p_user_id) AND NOT glur_private.is_developer(p_shop_id) THEN RAISE EXCEPTION ''Developer account protected''; END IF;','i');
EXECUTE def;
END IF;
END $guard$;