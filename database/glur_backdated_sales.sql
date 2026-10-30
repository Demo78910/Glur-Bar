ALTER TABLE public.glur_sales
 ADD COLUMN IF NOT EXISTS is_backdated boolean NOT NULL DEFAULT false,
 ADD COLUMN IF NOT EXISTS backdated_business_date date;
CREATE OR REPLACE FUNCTION public.glur_record_backdated_sale(p_shop_id uuid,p_recipe_id uuid,p_quantity integer,p_note text,p_business_date date,p_request_key uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_sale uuid; s public.glur_sales%ROWTYPE; v_today date:=((clock_timestamp() AT TIME ZONE 'Asia/Bangkok')-interval '3 hours')::date;
BEGIN
 IF auth.uid() IS NULL OR NOT coalesce(public.glur_stock_allowed(p_shop_id,'sales_create'),false) THEN RAISE EXCEPTION 'Permission denied'; END IF;
 IF p_business_date IS NULL OR p_business_date>=v_today THEN RAISE EXCEPTION 'Choose a past business date'; END IF;
 IF btrim(coalesce(p_note,''))='' OR length(p_note)>2000 THEN RAISE EXCEPTION 'Reason required, maximum 2000 characters'; END IF;
 IF p_request_key IS NULL THEN RAISE EXCEPTION 'Request key required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_shop_id::text||':'||p_request_key::text,0));
 SELECT x.* INTO s FROM public.glur_sales x JOIN public.glur_sale_request_keys k ON k.sale_id=x.id WHERE k.shop_id=p_shop_id AND k.request_key=p_request_key;
 IF FOUND AND NOT s.is_backdated THEN RAISE EXCEPTION 'Request key belongs to a normal sale'; END IF;
 -- The existing RPC owns recipe validation, stock locks, costs and retry protection.
 v_sale:=public.glur_record_sale_safe(p_shop_id,p_recipe_id,p_quantity,p_note,p_request_key);
 SELECT * INTO s FROM public.glur_sales WHERE id=v_sale AND shop_id=p_shop_id FOR UPDATE;
 IF s.is_backdated THEN
  IF s.backdated_business_date IS DISTINCT FROM p_business_date THEN RAISE EXCEPTION 'Request key reused with a different date'; END IF;
  RETURN v_sale;
 END IF;
 UPDATE public.glur_sales SET sold_at=(p_business_date::timestamp+interval '12 hours') AT TIME ZONE 'Asia/Bangkok',
 is_backdated=true,backdated_business_date=p_business_date WHERE id=v_sale AND shop_id=p_shop_id;
 RETURN v_sale;
END $$;
REVOKE ALL ON FUNCTION public.glur_record_backdated_sale(uuid,uuid,integer,text,date,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_record_backdated_sale(uuid,uuid,integer,text,date,uuid) TO authenticated;
NOTIFY pgrst,'reload schema';