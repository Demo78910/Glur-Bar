-- REVIEW BEFORE APPLY. TEST shop only. Does not modify LIVE or stock balances.
-- New independent RPC for resetting TEST financial transactions while keeping recipes/stock.
CREATE OR REPLACE FUNCTION public.glur_reset_test_transactions(
  p_shop_id uuid, p_reason text, p_confirmation text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_counts jsonb := '{}'::jsonb;
  v_n bigint;
BEGIN
  IF p_shop_id IS DISTINCT FROM 'e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af'::uuid THEN
    RAISE EXCEPTION 'TEST ONLY: LIVE reset prohibited';
  END IF;
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.glur_members
    WHERE shop_id=p_shop_id AND user_id=v_uid AND role='owner'
  ) THEN RAISE EXCEPTION 'Owner permission required'; END IF;
  IF p_confirmation IS DISTINCT FROM 'RESET TEST SALES' THEN
    RAISE EXCEPTION 'Confirmation mismatch';
  END IF;
  IF length(btrim(coalesce(p_reason,''))) < 10 THEN
    RAISE EXCEPTION 'Reason too short';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_shop_id::text,71289));
  LOCK TABLE public.glur_test_closing_stock_snapshots,
    public.glur_daily_closings,public.glur_sale_adjustments,
    public.glur_sale_ingredients,public.glur_sale_items,
    public.glur_sales,public.glur_expenses IN SHARE ROW EXCLUSIVE MODE;

  DELETE FROM public.glur_test_closing_stock_snapshots WHERE shop_id=p_shop_id;
  GET DIAGNOSTICS v_n=ROW_COUNT;
  v_counts:=v_counts||jsonb_build_object('closing_stock_snapshots',v_n);
  DELETE FROM public.glur_daily_closings WHERE shop_id=p_shop_id;
  GET DIAGNOSTICS v_n=ROW_COUNT;
  v_counts:=v_counts||jsonb_build_object('closings',v_n);
  DELETE FROM public.glur_sale_adjustments WHERE shop_id=p_shop_id;
  GET DIAGNOSTICS v_n=ROW_COUNT;
  v_counts:=v_counts||jsonb_build_object('sale_adjustments',v_n);
  DELETE FROM public.glur_sale_ingredients si USING public.glur_sales s
    WHERE si.sale_id=s.id AND s.shop_id=p_shop_id;
  GET DIAGNOSTICS v_n=ROW_COUNT;
  v_counts:=v_counts||jsonb_build_object('sale_ingredients',v_n);
  DELETE FROM public.glur_sale_items WHERE shop_id=p_shop_id;
  GET DIAGNOSTICS v_n=ROW_COUNT;
  v_counts:=v_counts||jsonb_build_object('sale_items',v_n);
  DELETE FROM public.glur_sales WHERE shop_id=p_shop_id;
  GET DIAGNOSTICS v_n=ROW_COUNT;
  v_counts:=v_counts||jsonb_build_object('sales',v_n);
  DELETE FROM public.glur_expenses WHERE shop_id=p_shop_id;
  GET DIAGNOSTICS v_n=ROW_COUNT;
  v_counts:=v_counts||jsonb_build_object('expenses',v_n);

  INSERT INTO public.glur_data_reset_audit
    (shop_id,requested_by,scope,reason,deleted_counts,stock_restorations)
  VALUES (p_shop_id,v_uid,'test_transactions',btrim(p_reason),v_counts,'[]'::jsonb);
  RETURN jsonb_build_object('scope','test_transactions','deleted_counts',v_counts,
    'stock_balances_unchanged',true,'recipes_unchanged',true);
END;
$$;
REVOKE ALL ON FUNCTION public.glur_reset_test_transactions(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_reset_test_transactions(uuid,text,text) TO authenticated;
