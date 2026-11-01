CREATE TABLE public.glur_recipe_cost_versions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),shop_id uuid NOT NULL REFERENCES public.glur_shops(id),
 recipe_id uuid NOT NULL REFERENCES public.glur_recipes(id),effective_on date NOT NULL,
 ingredients jsonb NOT NULL,note text NOT NULL,created_by uuid NOT NULL DEFAULT auth.uid(),created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(shop_id,recipe_id,effective_on));
ALTER TABLE public.glur_recipe_cost_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.glur_recipe_cost_versions FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.glur_recipe_cost_versions TO authenticated;
CREATE POLICY recipe_versions_read ON public.glur_recipe_cost_versions FOR SELECT TO authenticated USING(public.glur_stock_allowed(shop_id,'recipes_view'));
ALTER TABLE public.glur_sales ADD COLUMN IF NOT EXISTS original_total_cost numeric, ADD COLUMN IF NOT EXISTS cost_version_id uuid REFERENCES public.glur_recipe_cost_versions(id);
CREATE OR REPLACE FUNCTION glur_private.recipe_version_cost(p_shop uuid,p_recipe uuid,p_day date)
RETURNS TABLE(version_id uuid,unit_cost numeric) LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
SELECT v.id,coalesce(sum((i->>'quantity')::numeric * CASE WHEN i->>'stock_id' IS NOT NULL THEN coalesce(
(SELECT h.cost_per_unit FROM public.glur_cost_history h WHERE h.shop_id=p_shop AND h.stock_id=(i->>'stock_id')::uuid AND h.effective_on<=p_day ORDER BY h.effective_on DESC,h.created_at DESC LIMIT 1),(i->>'unit_cost')::numeric)
ELSE (i->>'unit_cost')::numeric END),0)
FROM (SELECT * FROM public.glur_recipe_cost_versions WHERE shop_id=p_shop AND recipe_id=p_recipe AND effective_on<=p_day ORDER BY effective_on DESC LIMIT 1) v
LEFT JOIN LATERAL jsonb_array_elements(v.ingredients) i ON true GROUP BY v.id;
$$;
REVOKE ALL ON FUNCTION glur_private.recipe_version_cost(uuid,uuid,date) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.glur_save_recipe_cost_version(p_shop_id uuid,p_recipe_id uuid,p_effective_on date,p_note text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE parts jsonb; affected integer;
BEGIN
IF NOT glur_private.is_developer(p_shop_id) THEN RAISE EXCEPTION 'Developer only: historical recipe correction'; END IF;
IF p_effective_on IS NULL OR p_effective_on>(now() AT TIME ZONE 'Asia/Bangkok')::date OR btrim(coalesce(p_note,''))='' THEN RAISE EXCEPTION 'Past/current start date and reason required'; END IF;
PERFORM 1 FROM public.glur_recipes WHERE id=p_recipe_id AND shop_id=p_shop_id FOR UPDATE;
IF NOT FOUND THEN RAISE EXCEPTION 'Recipe not in shop'; END IF;
SELECT jsonb_agg(x) INTO parts FROM(
SELECT jsonb_build_object('stock_id',s.id,'name',s.name,'quantity',r.quantity,'unit',s.unit,'unit_cost',s.cost_per_unit) x
FROM public.glur_recipe_ingredients r JOIN public.glur_stock s ON s.id=r.stock_id AND s.shop_id=r.shop_id WHERE r.recipe_id=p_recipe_id AND r.shop_id=p_shop_id
UNION ALL SELECT jsonb_build_object('name',n.name,'quantity',n.quantity,'unit',n.unit,'unit_cost',CASE WHEN n.package_size>0 THEN n.purchase_price/n.package_size ELSE coalesce(n.cost_per_unit,0) END) FROM public.glur_recipe_nonstock_ingredients n WHERE n.recipe_id=p_recipe_id AND n.shop_id=p_shop_id) z;
IF parts IS NULL THEN RAISE EXCEPTION 'Recipe has no ingredients'; END IF;
INSERT INTO public.glur_recipe_cost_versions(shop_id,recipe_id,effective_on,ingredients,note) VALUES(p_shop_id,p_recipe_id,p_effective_on,parts,p_note)
ON CONFLICT(shop_id,recipe_id,effective_on) DO UPDATE SET ingredients=excluded.ingredients,note=excluded.note,created_by=auth.uid(),created_at=now();
UPDATE public.glur_sales s SET original_total_cost=coalesce(s.original_total_cost,s.total_cost),total_cost=c.unit_cost*s.quantity_sold,cost_version_id=c.version_id,updated_by=auth.uid(),updated_at=now()
FROM public.glur_sales target CROSS JOIN LATERAL glur_private.recipe_version_cost(target.shop_id,target.recipe_id,((target.sold_at AT TIME ZONE 'Asia/Bangkok')-interval '3 hours')::date) c
WHERE s.id=target.id AND s.shop_id=p_shop_id AND s.recipe_id=p_recipe_id AND ((s.sold_at AT TIME ZONE 'Asia/Bangkok')-interval '3 hours')::date>=p_effective_on;
GET DIAGNOSTICS affected=ROW_COUNT;RETURN affected;
END $$;
REVOKE ALL ON FUNCTION public.glur_save_recipe_cost_version(uuid,uuid,date,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.glur_save_recipe_cost_version(uuid,uuid,date,text) TO authenticated;
CREATE OR REPLACE FUNCTION glur_private.apply_recipe_cost_version()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c record;
BEGIN
SELECT * INTO c FROM glur_private.recipe_version_cost(NEW.shop_id,NEW.recipe_id,((NEW.sold_at AT TIME ZONE 'Asia/Bangkok')-interval '3 hours')::date);
IF FOUND THEN UPDATE public.glur_sales SET original_total_cost=coalesce(original_total_cost,total_cost),total_cost=c.unit_cost*NEW.quantity_sold,cost_version_id=c.version_id WHERE id=NEW.id; END IF;
RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION glur_private.apply_recipe_cost_version() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER glur_recipe_version_on_sale AFTER INSERT OR UPDATE OF sold_at ON public.glur_sales FOR EACH ROW EXECUTE FUNCTION glur_private.apply_recipe_cost_version();
NOTIFY pgrst,'reload schema';
CREATE TRIGGER glur_recipe_version_audit AFTER INSERT OR UPDATE ON public.glur_recipe_cost_versions FOR EACH ROW EXECUTE FUNCTION public.glur_activity_capture();
DROP TRIGGER glur_recipe_version_on_sale ON public.glur_sales;
CREATE TRIGGER glur_recipe_version_on_sale AFTER UPDATE OF sold_at ON public.glur_sales FOR EACH ROW EXECUTE FUNCTION glur_private.apply_recipe_cost_version();