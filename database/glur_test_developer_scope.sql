CREATE OR REPLACE FUNCTION public.glur_stock_allowed(p_shop_id uuid,p_key text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
SELECT (p_shop_id<>'e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af'::uuid OR glur_private.is_developer(p_shop_id))
AND EXISTS(SELECT 1 FROM public.glur_members m WHERE m.shop_id=p_shop_id AND m.user_id=auth.uid() AND (m.role='owner' OR EXISTS(SELECT 1 FROM public.glur_member_permissions p WHERE p.shop_id=m.shop_id AND p.user_id=m.user_id AND p.permission_key=p_key AND p.allowed IS TRUE)));
$$;
DO $guard$ DECLARE t record; f record; def text; BEGIN
FOR t IN SELECT table_name FROM information_schema.columns WHERE table_schema='public' AND column_name='shop_id' AND table_name IN(SELECT tablename FROM pg_tables WHERE schemaname='public') LOOP
IF NOT EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=t.table_name AND policyname='glur_test_developer_only') THEN
EXECUTE format('CREATE POLICY glur_test_developer_only ON public.%I AS RESTRICTIVE FOR ALL TO authenticated USING (shop_id<>%L::uuid OR public.glur_is_developer(shop_id)) WITH CHECK(shop_id<>%L::uuid OR public.glur_is_developer(shop_id))',t.table_name,'e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af','e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af');
END IF; END LOOP;
FOR f IN SELECT p.oid FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.pronamespace='public'::regnamespace AND l.lanname='plpgsql' AND 'p_shop_id'=ANY(p.proargnames) LOOP
def:=pg_get_functiondef(f.oid);
IF position('GLUR_TEST_DEVELOPER_GATE' IN def)=0 THEN
def:=regexp_replace(def,'\mBEGIN\M','BEGIN /* GLUR_TEST_DEVELOPER_GATE */ IF p_shop_id=''e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af''::uuid AND NOT glur_private.is_developer(p_shop_id) THEN RAISE EXCEPTION ''Developer only: TEST''; END IF;','i');EXECUTE def;
END IF;END LOOP;
END $guard$;