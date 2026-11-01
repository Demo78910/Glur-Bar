CREATE OR REPLACE FUNCTION public.glur_employee_profiles_list(p_shop_id uuid)
 RETURNS TABLE(user_id uuid, username text, display_name text, role text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS (
 SELECT 1 FROM public.glur_members m WHERE m.shop_id=p_shop_id AND m.user_id=auth.uid() AND m.role IN ('owner','manager')
 ) THEN RAISE EXCEPTION 'Owner/Manager only'; END IF;
 RETURN QUERY
 SELECT m.user_id,u.username::text,p.display_name::text,m.role::text
 FROM public.glur_members m
 LEFT JOIN public.glur_usernames u ON u.user_id=m.user_id
 LEFT JOIN public.glur_employee_profiles p ON p.shop_id=m.shop_id AND p.user_id=m.user_id
 WHERE m.shop_id=p_shop_id
 AND (glur_private.is_developer(p_shop_id) OR NOT EXISTS(SELECT 1 FROM public.glur_system_developers d WHERE d.user_id=m.user_id));
END $$;
DO $guard$
DECLARE f record; def text; target text;
BEGIN
 FOR f IN SELECT oid,proname FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname IN ('glur_get_member_permissions','glur_set_member_permissions','glur_employee_profile_set')
 LOOP
 def:=pg_get_functiondef(f.oid);
 IF position('GLUR_HIDE_DEVELOPER_TARGET' IN def)=0 THEN
 target:=CASE WHEN f.proname='glur_employee_profile_set' THEN 'p_user_id' ELSE 'p_target_user' END;
 def:=regexp_replace(def,'\mBEGIN\M','BEGIN /* GLUR_HIDE_DEVELOPER_TARGET */ IF EXISTS(SELECT 1 FROM public.glur_system_developers d WHERE d.user_id='||target||') AND NOT glur_private.is_developer(p_shop_id) THEN RAISE EXCEPTION ''Target not in shop''; END IF;','i');
 EXECUTE def;
 END IF;
 END LOOP;
END $guard$;
NOTIFY pgrst,'reload schema';