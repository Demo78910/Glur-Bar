CREATE OR REPLACE FUNCTION public.glur_test_capture_closing_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 insert into public.glur_test_closing_stock_snapshots(closing_id,shop_id,stock_id,stock_name,unit,quantity,cost_per_unit)
 select new.id,new.shop_id,s.id,s.name,s.unit,s.quantity,s.cost_per_unit from public.glur_stock s where s.shop_id=new.shop_id;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION public.glur_test_sale_ingredient_movement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_shop uuid;
  v_before numeric;
  v_cost numeric;
BEGIN
  SELECT shop_id INTO v_shop FROM public.glur_sales WHERE id=NEW.sale_id;
  IF NEW.quantity_used IS NULL OR NEW.quantity_used <= 0 THEN
    RAISE EXCEPTION 'Invalid sale ingredient quantity';
  END IF;
  SELECT quantity,cost_per_unit INTO v_before,v_cost
    FROM public.glur_stock WHERE id=NEW.stock_id AND shop_id=v_shop FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stock missing for sale ingredient'; END IF;
  IF v_before < NEW.quantity_used THEN
    RAISE EXCEPTION 'Insufficient stock for sale';
  END IF;
  INSERT INTO public.glur_stock_movements
    (shop_id,stock_id,movement_type,quantity_before,quantity_change,quantity_after,
     cost_per_unit_snapshot,reason,reference_id,created_by)
  VALUES
    (v_shop,NEW.stock_id,'sale',v_before,-NEW.quantity_used,v_before-NEW.quantity_used,
     NEW.cost_per_unit,'ตัดใช้จากการขาย',NEW.sale_id,auth.uid());
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.glur_manual_consumption(p_shop_id uuid, p_stock_id uuid, p_quantity numeric, p_purpose text, p_note text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_before numeric; v_cost numeric; v_id uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.glur_members WHERE shop_id=p_shop_id AND user_id=auth.uid() AND role IN ('owner','manager')) THEN RAISE EXCEPTION 'Not authorized'; END IF;
 IF p_quantity IS NULL OR p_quantity<=0 OR p_quantity::text IN ('NaN','Infinity','-Infinity') OR p_purpose IS NULL OR p_purpose NOT IN ('garnish','juice','prep','other') THEN RAISE EXCEPTION 'Invalid quantity or purpose'; END IF;
 SELECT quantity,cost_per_unit INTO v_before,v_cost FROM public.glur_stock WHERE id=p_stock_id AND shop_id=p_shop_id FOR UPDATE;
 IF NOT FOUND OR v_before<p_quantity THEN RAISE EXCEPTION 'Insufficient stock'; END IF;
 UPDATE public.glur_stock SET quantity=quantity-p_quantity WHERE id=p_stock_id AND shop_id=p_shop_id;
 INSERT INTO public.glur_stock_movements(shop_id,stock_id,movement_type,quantity_before,quantity_change,quantity_after,cost_per_unit_snapshot,reason,created_by)
 VALUES(p_shop_id,p_stock_id,'manual_adjustment',v_before,-p_quantity,v_before-p_quantity,v_cost,'ใช้จริง: '||p_purpose||' · '||left(coalesce(p_note,''),300),auth.uid()) RETURNING id INTO v_id;
 RETURN v_id;
END $function$;

REVOKE ALL ON FUNCTION public.glur_manual_consumption(uuid,uuid,numeric,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_manual_consumption(uuid,uuid,numeric,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.glur_test_capture_closing_stock(),public.glur_test_sale_ingredient_movement() FROM PUBLIC,anon,authenticated;
DROP POLICY IF EXISTS test_snapshot_members_read ON public.glur_test_closing_stock_snapshots;
CREATE POLICY closing_snapshot_members_read ON public.glur_test_closing_stock_snapshots FOR SELECT TO authenticated
 USING (EXISTS (SELECT 1 FROM public.glur_members m WHERE m.shop_id=glur_test_closing_stock_snapshots.shop_id AND m.user_id=(SELECT auth.uid())));

ALTER TABLE public.glur_sales ADD COLUMN IF NOT EXISTS nonstock_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb;
CREATE OR REPLACE FUNCTION public.glur_record_custom_cocktail_v2(
 p_shop_id uuid,p_name text,p_unit_price numeric,p_quantity integer,p_ingredients jsonb,p_nonstock jsonb DEFAULT '[]'::jsonb,p_note text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 v_user uuid:=auth.uid(); v_id uuid; v_cost numeric:=0; v_unit_cost numeric;
 v_row record; v_stock public.glur_stock%rowtype; v_catalog public.glur_cost_catalog%rowtype;
 v_history record; v_snapshot jsonb:='[]'::jsonb; v_today date:=(now() at time zone 'Asia/Bangkok')::date;
BEGIN
 IF v_user IS NULL OR NOT public.glur_stock_allowed(p_shop_id,'sales_create') THEN RAISE EXCEPTION 'ไม่มีสิทธิ์บันทึกขายในร้านนี้'; END IF;
 IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 150 OR p_quantity IS NULL OR p_quantity NOT BETWEEN 1 AND 10000 OR p_unit_price IS NULL OR p_unit_price::text IN ('NaN','Infinity','-Infinity') OR p_unit_price<0 OR p_unit_price>1000000 OR length(coalesce(p_note,''))>2000 THEN RAISE EXCEPTION 'ข้อมูลการขายไม่ถูกต้อง'; END IF;
 IF p_ingredients IS NULL OR p_nonstock IS NULL OR jsonb_typeof(p_ingredients)<>'array' OR jsonb_typeof(p_nonstock)<>'array' THEN RAISE EXCEPTION 'ส่วนผสมต้องเป็นรายการ'; END IF;
 IF jsonb_array_length(p_ingredients)+jsonb_array_length(p_nonstock) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'ระบุส่วนผสม 1–100 รายการ'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_ingredients) AS x(stock_id uuid,quantity numeric) WHERE stock_id IS NULL OR quantity IS NULL OR quantity::text IN ('NaN','Infinity','-Infinity') OR quantity<=0 OR quantity>1000000)
 OR EXISTS(SELECT 1 FROM jsonb_to_recordset(p_nonstock) AS x(catalog_id uuid,quantity numeric) WHERE catalog_id IS NULL OR quantity IS NULL OR quantity::text IN ('NaN','Infinity','-Infinity') OR quantity<=0 OR quantity>1000000) THEN RAISE EXCEPTION 'วัตถุดิบหรือปริมาณไม่ถูกต้อง'; END IF;
 -- Match the closing gate's lock order before taking stock locks.
 PERFORM pg_advisory_xact_lock(hashtextextended('glur:closing:'||p_shop_id::text,0));
 PERFORM s.id FROM public.glur_stock s WHERE s.shop_id=p_shop_id AND s.id IN(SELECT x.stock_id FROM jsonb_to_recordset(p_ingredients) AS x(stock_id uuid,quantity numeric)) ORDER BY s.id FOR UPDATE;
 FOR v_row IN SELECT x.stock_id,sum(x.quantity) AS quantity FROM jsonb_to_recordset(p_ingredients) AS x(stock_id uuid,quantity numeric) GROUP BY x.stock_id ORDER BY x.stock_id LOOP
  SELECT * INTO v_stock FROM public.glur_stock WHERE id=v_row.stock_id AND shop_id=p_shop_id AND is_active IS DISTINCT FROM false;
  IF NOT FOUND THEN RAISE EXCEPTION 'ไม่พบวัตถุดิบในร้านนี้'; END IF;
  IF v_stock.quantity<v_row.quantity*p_quantity THEN RAISE EXCEPTION 'สต๊อก % ไม่พอ',v_stock.name; END IF;
  SELECT h.cost_per_unit INTO v_unit_cost FROM public.glur_cost_history h WHERE h.shop_id=p_shop_id AND h.stock_id=v_stock.id AND h.effective_on<=v_today ORDER BY h.effective_on DESC,h.created_at DESC LIMIT 1;
  IF NOT FOUND THEN v_unit_cost:=CASE WHEN EXISTS(SELECT 1 FROM public.glur_cost_history h WHERE h.shop_id=p_shop_id AND h.stock_id=v_stock.id) THEN 0 ELSE v_stock.cost_per_unit END; END IF;
  v_cost:=v_cost+v_row.quantity*p_quantity*coalesce(v_unit_cost,0);
 END LOOP;
 FOR v_row IN SELECT x.catalog_id,sum(x.quantity) AS quantity FROM jsonb_to_recordset(p_nonstock) AS x(catalog_id uuid,quantity numeric) GROUP BY x.catalog_id ORDER BY x.catalog_id LOOP
  SELECT * INTO v_catalog FROM public.glur_cost_catalog WHERE id=v_row.catalog_id AND shop_id=p_shop_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ไม่พบวัตถุดิบไม่ตัดสต๊อกในร้านนี้'; END IF;
  SELECT h.purchase_price,h.package_size INTO v_history FROM public.glur_cost_catalog_history h WHERE h.shop_id=p_shop_id AND h.catalog_id=v_catalog.id AND h.effective_date<=v_today ORDER BY h.effective_date DESC,h.created_at DESC LIMIT 1;
  IF FOUND THEN
   IF v_history.purchase_price IS NULL OR v_history.package_size IS NULL OR v_history.package_size<=0 THEN RAISE EXCEPTION 'ยังไม่ระบุราคาของ %',v_catalog.name; END IF;
   v_unit_cost:=v_history.purchase_price/v_history.package_size;
  ELSE
   IF EXISTS(SELECT 1 FROM public.glur_cost_catalog_history h WHERE h.shop_id=p_shop_id AND h.catalog_id=v_catalog.id) OR v_catalog.package_size<=0 THEN RAISE EXCEPTION 'ยังไม่มีราคาที่ใช้ได้วันนี้ของ %',v_catalog.name; END IF;
   v_unit_cost:=v_catalog.purchase_price/v_catalog.package_size;
  END IF;
  v_cost:=v_cost+v_row.quantity*p_quantity*v_unit_cost;
  v_snapshot:=v_snapshot||jsonb_build_array(jsonb_build_object('catalog_id',v_catalog.id,'name',v_catalog.name,'unit',v_catalog.unit,'quantity_per_glass',v_row.quantity,'quantity_used',v_row.quantity*p_quantity,'cost_per_unit',v_unit_cost));
 END LOOP;
 INSERT INTO public.glur_sales(shop_id,sold_by,recipe_name,quantity_sold,unit_price,total_amount,total_cost,note,nonstock_snapshot)
 VALUES(p_shop_id,v_user,btrim(p_name),p_quantity,p_unit_price,p_unit_price*p_quantity,v_cost,nullif(btrim(p_note),''),v_snapshot) RETURNING id INTO v_id;
 FOR v_row IN SELECT x.stock_id,sum(x.quantity)*p_quantity AS quantity FROM jsonb_to_recordset(p_ingredients) AS x(stock_id uuid,quantity numeric) GROUP BY x.stock_id ORDER BY x.stock_id LOOP
  SELECT h.cost_per_unit INTO v_unit_cost FROM public.glur_cost_history h WHERE h.shop_id=p_shop_id AND h.stock_id=v_row.stock_id AND h.effective_on<=v_today ORDER BY h.effective_on DESC,h.created_at DESC LIMIT 1;
  IF NOT FOUND THEN SELECT CASE WHEN EXISTS(SELECT 1 FROM public.glur_cost_history h WHERE h.shop_id=p_shop_id AND h.stock_id=s.id) THEN 0 ELSE s.cost_per_unit END INTO v_unit_cost FROM public.glur_stock s WHERE s.id=v_row.stock_id AND s.shop_id=p_shop_id; END IF;
  INSERT INTO public.glur_sale_ingredients(sale_id,stock_id,quantity_used,cost_per_unit) VALUES(v_id,v_row.stock_id,v_row.quantity,coalesce(v_unit_cost,0));
  UPDATE public.glur_stock SET quantity=quantity-v_row.quantity WHERE id=v_row.stock_id AND shop_id=p_shop_id;
 END LOOP;
 RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.glur_record_custom_cocktail_v2(uuid,text,numeric,integer,jsonb,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_record_custom_cocktail_v2(uuid,text,numeric,integer,jsonb,jsonb,text) TO authenticated;
NOTIFY pgrst,'reload schema';

CREATE OR REPLACE FUNCTION public.glur_record_sale_v2(p_shop_id uuid, p_recipe_id uuid, p_quantity integer, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user uuid;
  v_recipe public.glur_recipes%ROWTYPE;
  v_item record;
  v_sale_id uuid;
  v_total_cost numeric := 0;
  v_amount numeric;
  v_cost numeric;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_quantity IS NULL OR p_quantity <= 0
     OR p_quantity > 10000 THEN
    RAISE EXCEPTION 'Invalid sale quantity';
  END IF;

  IF NOT EXISTS (
    SELECT 1 WHERE public.glur_stock_allowed(p_shop_id, 'sales_create')
  ) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  SELECT *
  INTO v_recipe
  FROM public.glur_recipes
  WHERE id = p_recipe_id
    AND shop_id = p_shop_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Recipe not found';
  END IF;

  IF v_recipe.selling_price IS NULL
     OR v_recipe.selling_price < 0 THEN
    RAISE EXCEPTION 'Invalid recipe price';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.glur_recipe_ingredients WHERE recipe_id=p_recipe_id AND shop_id=p_shop_id) AND NOT EXISTS (SELECT 1 FROM public.glur_recipe_nonstock_ingredients WHERE recipe_id=p_recipe_id AND shop_id=p_shop_id) THEN
    RAISE EXCEPTION 'Recipe has no ingredients';
  END IF;

  -- ล็อกวัตถุดิบทุกตัวตามลำดับ ID
  -- ป้องกันยอดคลาดเคลื่อนเมื่อขายพร้อมกัน
  PERFORM s.id
  FROM public.glur_stock s
  WHERE s.shop_id = p_shop_id
    AND s.id IN (
      SELECT ri.stock_id
      FROM public.glur_recipe_ingredients ri
      WHERE ri.recipe_id = p_recipe_id
        AND ri.shop_id = p_shop_id
    )
  ORDER BY s.id
  FOR UPDATE OF s;

  -- ตรวจสอบว่าวัตถุดิบในสูตรครบและถูกต้อง
  IF EXISTS (
    SELECT 1
    FROM public.glur_recipe_ingredients ri
    LEFT JOIN public.glur_stock s
      ON s.id = ri.stock_id
      AND s.shop_id = p_shop_id
    WHERE ri.recipe_id = p_recipe_id
      AND ri.shop_id = p_shop_id
      AND (
        s.id IS NULL
        OR ri.quantity IS NULL
        OR ri.quantity <= 0
      )
  ) THEN
    RAISE EXCEPTION 'Invalid recipe ingredients';
  END IF;

  -- คำนวณต้นทุนตามราคาสต๊อก ณ เวลาขาย
  SELECT COALESCE(
    SUM(ri.quantity * p_quantity * COALESCE((SELECT h.cost_per_unit FROM public.glur_cost_history h WHERE h.shop_id=p_shop_id AND h.stock_id=s.id AND h.effective_on <= (now() AT TIME ZONE 'Asia/Bangkok')::date ORDER BY h.effective_on DESC,h.created_at DESC LIMIT 1), CASE WHEN EXISTS(SELECT 1 FROM public.glur_cost_history hx WHERE hx.shop_id=p_shop_id AND hx.stock_id=s.id) THEN 0 ELSE s.cost_per_unit END)),
    0
  )
  INTO v_total_cost
  FROM public.glur_recipe_ingredients ri
  JOIN public.glur_stock s
    ON s.id = ri.stock_id
    AND s.shop_id = p_shop_id
  WHERE ri.recipe_id = p_recipe_id
    AND ri.shop_id = p_shop_id;

  SELECT v_total_cost + COALESCE(SUM(ni.quantity * p_quantity * CASE
 WHEN cv.id IS NOT NULL THEN CASE WHEN cv.package_size > 0 THEN cv.purchase_price/cv.package_size ELSE 0 END
 WHEN c.id IS NOT NULL AND EXISTS(SELECT 1 FROM public.glur_cost_catalog_history cx WHERE cx.shop_id=p_shop_id AND cx.catalog_id=c.id) THEN 0
 WHEN c.id IS NOT NULL AND c.package_size > 0 THEN c.purchase_price/c.package_size
 WHEN ni.package_size > 0 THEN ni.purchase_price/ni.package_size
 ELSE 0 END),0) INTO v_total_cost
 FROM public.glur_recipe_nonstock_ingredients ni
 LEFT JOIN LATERAL (SELECT cc.* FROM public.glur_cost_catalog cc WHERE cc.shop_id=p_shop_id AND lower(btrim(cc.name))=lower(btrim(ni.name)) AND lower(btrim(cc.unit))=lower(btrim(ni.unit)) ORDER BY cc.updated_at DESC LIMIT 1) c ON true
 LEFT JOIN LATERAL (SELECT ch.* FROM public.glur_cost_catalog_history ch WHERE ch.shop_id=p_shop_id AND ch.catalog_id=c.id AND ch.effective_date <= (now() AT TIME ZONE 'Asia/Bangkok')::date ORDER BY ch.effective_date DESC,ch.created_at DESC LIMIT 1) cv ON true
 WHERE ni.shop_id=p_shop_id AND ni.recipe_id=p_recipe_id;
  -- บันทึกยอดขาย
  INSERT INTO public.glur_sales (
    shop_id,
    sold_by,
    recipe_id,
    recipe_name,
    quantity_sold,
    unit_price,
    total_amount,
    total_cost,
    note
  )
  VALUES (
    p_shop_id,
    v_user,
    p_recipe_id,
    v_recipe.name,
    p_quantity,
    v_recipe.selling_price,
    v_recipe.selling_price * p_quantity,
    v_total_cost,
    NULLIF(BTRIM(p_note), '')
  )
  RETURNING id INTO v_sale_id;

  -- บันทึกวัตถุดิบและตัดสต๊อก
  FOR v_item IN
    SELECT
      ri.stock_id,
      SUM(ri.quantity) * p_quantity AS amount,
      COALESCE((SELECT h.cost_per_unit FROM public.glur_cost_history h WHERE h.shop_id=p_shop_id AND h.stock_id=s.id AND h.effective_on <= (now() AT TIME ZONE 'Asia/Bangkok')::date ORDER BY h.effective_on DESC,h.created_at DESC LIMIT 1), CASE WHEN EXISTS(SELECT 1 FROM public.glur_cost_history hx WHERE hx.shop_id=p_shop_id AND hx.stock_id=s.id) THEN 0 ELSE s.cost_per_unit END) AS cost
    FROM public.glur_recipe_ingredients ri
    JOIN public.glur_stock s
      ON s.id = ri.stock_id
      AND s.shop_id = p_shop_id
    WHERE ri.recipe_id = p_recipe_id
      AND ri.shop_id = p_shop_id
    GROUP BY ri.stock_id, s.id, s.cost_per_unit
    ORDER BY ri.stock_id
  LOOP
    INSERT INTO public.glur_sale_ingredients (
      sale_id,
      stock_id,
      quantity_used,
      cost_per_unit
    )
    VALUES (
      v_sale_id,
      v_item.stock_id,
      v_item.amount,
      v_item.cost
    );

    UPDATE public.glur_stock
    SET quantity = quantity - v_item.amount
    WHERE id = v_item.stock_id
      AND shop_id = p_shop_id;
  END LOOP;

  RETURN v_sale_id;
END;
$function$;
CREATE OR REPLACE FUNCTION public.glur_produce_prebatch(p_recipe_id uuid, p_multiplier numeric, p_yield numeric, p_notes text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_uid uuid:=auth.uid();v_r public.glur_prebatch_recipes%ROWTYPE;v_input record;v_out public.glur_stock%ROWTYPE;
 v_need numeric;v_total numeric:=0;v_batch uuid;v_old_qty numeric;v_new_qty numeric;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF p_multiplier IS NULL OR p_multiplier<=0 OR p_yield IS NULL OR p_yield<=0 THEN RAISE EXCEPTION 'Multiplier and yield must be positive'; END IF;
 SELECT * INTO v_r FROM public.glur_prebatch_recipes WHERE id=p_recipe_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Recipe not found'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.glur_members WHERE shop_id=v_r.shop_id AND user_id=v_uid AND role IN ('owner','manager','staff')) THEN RAISE EXCEPTION 'Not a shop member'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.glur_prebatch_ingredients WHERE recipe_id=v_r.id) THEN RAISE EXCEPTION 'No ingredients'; END IF;
 -- Lock every affected stock row in deterministic order to avoid concurrent lost updates/deadlocks.
 PERFORM 1 FROM public.glur_stock WHERE shop_id=v_r.shop_id AND id IN (
   SELECT stock_id FROM public.glur_prebatch_ingredients WHERE recipe_id=v_r.id UNION SELECT v_r.output_stock_id
 ) ORDER BY id FOR UPDATE;
 SELECT * INTO v_out FROM public.glur_stock WHERE id=v_r.output_stock_id AND shop_id=v_r.shop_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Output stock missing'; END IF;
 INSERT INTO public.glur_prebatch_batches(recipe_id,shop_id,multiplier,produced_qty,total_cost,produced_by,notes)
 VALUES(v_r.id,v_r.shop_id,p_multiplier,p_yield,0,v_uid,left(coalesce(p_notes,''),1000)) RETURNING id INTO v_batch;
 FOR v_input IN SELECT i.stock_id,i.quantity,s.quantity AS available,s.cost_per_unit FROM public.glur_prebatch_ingredients i
 JOIN public.glur_stock s ON s.id=i.stock_id AND s.shop_id=v_r.shop_id WHERE i.recipe_id=v_r.id ORDER BY i.stock_id LOOP
   v_need:=v_input.quantity*p_multiplier;
   IF v_input.available<v_need THEN RAISE EXCEPTION 'Insufficient stock for ingredient %: need %, available %',v_input.stock_id,v_need,v_input.available; END IF;
   UPDATE public.glur_stock SET quantity=quantity-v_need WHERE id=v_input.stock_id AND shop_id=v_r.shop_id;
   INSERT INTO public.glur_prebatch_batch_inputs(batch_id,stock_id,quantity_used,cost_per_unit) VALUES(v_batch,v_input.stock_id,v_need,v_input.cost_per_unit);
   v_total:=v_total+v_need*v_input.cost_per_unit;
 END LOOP;

 SELECT v_total+coalesce(sum(ni.quantity*p_multiplier*CASE
 WHEN cv.id IS NOT NULL THEN CASE WHEN cv.package_size>0 THEN coalesce(cv.purchase_price,0)/cv.package_size ELSE 0 END
 WHEN c.id IS NOT NULL AND EXISTS(SELECT 1 FROM public.glur_cost_catalog_history cx WHERE cx.shop_id=v_r.shop_id AND cx.catalog_id=c.id) THEN 0
 WHEN c.id IS NOT NULL AND c.package_size>0 THEN c.purchase_price/c.package_size
 WHEN ni.package_size>0 THEN ni.purchase_price/ni.package_size ELSE 0 END),0) INTO v_total
 FROM public.glur_prebatch_nonstock_ingredients ni
 LEFT JOIN LATERAL (SELECT cc.* FROM public.glur_cost_catalog cc WHERE cc.shop_id=v_r.shop_id AND lower(btrim(cc.name))=lower(btrim(ni.name)) AND lower(btrim(cc.unit))=lower(btrim(ni.unit)) ORDER BY cc.updated_at DESC LIMIT 1)c ON true
 LEFT JOIN LATERAL (SELECT h.* FROM public.glur_cost_catalog_history h WHERE h.shop_id=v_r.shop_id AND h.catalog_id=c.id AND h.effective_date<=(now() AT TIME ZONE 'Asia/Bangkok')::date ORDER BY h.effective_date DESC,h.created_at DESC LIMIT 1)cv ON true
 WHERE ni.recipe_id=v_r.id AND ni.shop_id=v_r.shop_id;

 v_old_qty:=v_out.quantity;v_new_qty:=v_old_qty+p_yield;
 IF v_old_qty<0 THEN RAISE EXCEPTION 'Output stock negative; reconcile stock first'; END IF;
 UPDATE public.glur_stock SET quantity=v_new_qty,
 cost_per_unit=CASE WHEN v_new_qty>0 THEN ((v_old_qty*v_out.cost_per_unit)+v_total)/v_new_qty ELSE 0 END
 WHERE id=v_out.id AND shop_id=v_r.shop_id;
 UPDATE public.glur_prebatch_batches SET total_cost=v_total WHERE id=v_batch;
 RETURN v_batch;
END $function$;
