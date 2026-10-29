CREATE OR REPLACE FUNCTION public.glur_test_manual_consumption(p_shop_id uuid,p_stock_id uuid,p_quantity numeric,p_purpose text,p_note text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE v_before numeric; v_cost numeric; v_id uuid;
BEGIN
 IF p_shop_id <> 'e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af'::uuid THEN RAISE EXCEPTION 'TEST only'; END IF;
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.glur_members WHERE shop_id=p_shop_id AND user_id=auth.uid() AND role IN ('owner','manager')) THEN RAISE EXCEPTION 'Not authorized'; END IF;
 IF p_quantity IS NULL OR p_quantity<=0 OR p_purpose NOT IN ('garnish','juice','prep','other') THEN RAISE EXCEPTION 'Invalid quantity or purpose'; END IF;
 SELECT quantity,cost_per_unit INTO v_before,v_cost FROM public.glur_stock WHERE id=p_stock_id AND shop_id=p_shop_id FOR UPDATE;
 IF NOT FOUND OR v_before<p_quantity THEN RAISE EXCEPTION 'Insufficient stock'; END IF;
 UPDATE public.glur_stock SET quantity=quantity-p_quantity WHERE id=p_stock_id AND shop_id=p_shop_id;
 INSERT INTO public.glur_stock_movements(shop_id,stock_id,movement_type,quantity_before,quantity_change,quantity_after,cost_per_unit_snapshot,reason,created_by)
 VALUES(p_shop_id,p_stock_id,'manual_use',v_before,-p_quantity,v_before-p_quantity,v_cost,'ใช้จริง: '||p_purpose||' · '||left(coalesce(p_note,''),300),auth.uid()) RETURNING id INTO v_id;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.glur_test_manual_consumption(uuid,uuid,numeric,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_test_manual_consumption(uuid,uuid,numeric,text,text) TO authenticated;