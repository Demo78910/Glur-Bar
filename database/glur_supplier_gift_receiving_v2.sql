ALTER TABLE public.glur_stock_receipts
 ADD COLUMN IF NOT EXISTS receipt_kind text NOT NULL DEFAULT 'purchase' CHECK(receipt_kind IN ('purchase','gift')),
 ADD COLUMN IF NOT EXISTS supplier text NOT NULL DEFAULT '',
 ADD COLUMN IF NOT EXISTS note text NOT NULL DEFAULT '',
 ADD COLUMN IF NOT EXISTS cost_policy text NOT NULL DEFAULT 'average' CHECK(cost_policy IN ('average','keep')),
 ADD COLUMN IF NOT EXISTS previous_unit_cost numeric,
 ADD COLUMN IF NOT EXISTS resulting_unit_cost numeric,
 ADD COLUMN IF NOT EXISTS request_key uuid;
CREATE UNIQUE INDEX IF NOT EXISTS glur_receipt_request_key ON public.glur_stock_receipts(shop_id,created_by,request_key) WHERE request_key IS NOT NULL;
CREATE OR REPLACE FUNCTION public.glur_receive_stock_v2(p_shop_id uuid,p_stock_id uuid,p_quantity numeric,p_total_cost numeric,p_receipt_kind text,p_supplier text,p_note text,p_cost_policy text,p_request_key uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE u uuid:=auth.uid(); s public.glur_stock%ROWTYPE; r uuid; q numeric; c numeric;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF NOT coalesce(public.glur_stock_allowed(p_shop_id,'receiving_manage'),false) THEN RAISE EXCEPTION 'Permission denied'; END IF;
 IF p_quantity IS NULL OR p_quantity<=0 OR p_quantity::text IN ('NaN','Infinity','-Infinity') OR p_total_cost IS NULL OR p_total_cost<0 OR p_total_cost::text IN ('NaN','Infinity','-Infinity') OR p_receipt_kind IS NULL OR p_receipt_kind NOT IN ('purchase','gift') OR p_cost_policy IS NULL OR p_cost_policy NOT IN ('average','keep') OR p_request_key IS NULL THEN RAISE EXCEPTION 'Invalid receipt input'; END IF;
 IF length(coalesce(p_supplier,''))>200 OR length(coalesce(p_note,''))>500 THEN RAISE EXCEPTION 'Text too long'; END IF;
 IF p_receipt_kind='gift' AND (p_total_cost<>0 OR btrim(coalesce(p_supplier,''))='') THEN RAISE EXCEPTION 'Gift requires zero cost and supplier'; END IF;
 IF p_receipt_kind='purchase' AND p_cost_policy<>'average' THEN RAISE EXCEPTION 'Purchase requires average cost'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_shop_id::text||u::text||p_request_key::text,0));
 SELECT id INTO r FROM public.glur_stock_receipts WHERE shop_id=p_shop_id AND created_by=u AND request_key=p_request_key;
 IF FOUND THEN RETURN r; END IF;
 SELECT * INTO s FROM public.glur_stock WHERE id=p_stock_id AND shop_id=p_shop_id FOR UPDATE;
 IF NOT FOUND OR NOT coalesce(s.is_active,true) THEN RAISE EXCEPTION 'Active stock not found in this shop'; END IF;
 q:=s.quantity+p_quantity;
 IF q<=0 THEN RAISE EXCEPTION 'Invalid resulting quantity'; END IF;
 c:=CASE WHEN p_cost_policy='keep' THEN s.cost_per_unit ELSE (s.quantity*s.cost_per_unit+p_total_cost)/q END;
 UPDATE public.glur_stock SET quantity=q,cost_per_unit=c WHERE id=s.id AND shop_id=p_shop_id;
 INSERT INTO public.glur_stock_receipts(shop_id,stock_id,quantity,total_cost,created_by,receipt_kind,supplier,note,cost_policy,previous_unit_cost,resulting_unit_cost,request_key)
 VALUES(p_shop_id,p_stock_id,p_quantity,p_total_cost,u,p_receipt_kind,btrim(coalesce(p_supplier,'')),btrim(coalesce(p_note,'')),p_cost_policy,s.cost_per_unit,c,p_request_key) RETURNING id INTO r;
 RETURN r;
END $$;
REVOKE ALL ON FUNCTION public.glur_receive_stock_v2(uuid,uuid,numeric,numeric,text,text,text,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_receive_stock_v2(uuid,uuid,numeric,numeric,text,text,text,text,uuid) TO authenticated;
ALTER TABLE public.glur_stock_receipts ADD CONSTRAINT glur_gift_zero_cost_supplier CHECK (receipt_kind <> 'gift' OR (total_cost=0 AND btrim(supplier)<>'')), ADD CONSTRAINT glur_purchase_average_policy CHECK (receipt_kind<>'purchase' OR cost_policy='average');
NOTIFY pgrst,'reload schema';
