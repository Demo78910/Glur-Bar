-- GLUR BAR non-stock ingredients (STAGING: do not run until UI review)
BEGIN;
CREATE TABLE public.glur_recipe_nonstock_ingredients (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 shop_id uuid NOT NULL REFERENCES public.glur_shops(id),
 recipe_id uuid NOT NULL,
 name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 150),
 quantity numeric NOT NULL CHECK (quantity > 0),
 unit text NOT NULL CHECK (length(btrim(unit)) BETWEEN 1 AND 30),
 cost_per_unit numeric NOT NULL DEFAULT 0 CHECK (cost_per_unit = 0),
 CONSTRAINT recipe_nonstock_parent FOREIGN KEY(recipe_id,shop_id)
 REFERENCES public.glur_recipes(id,shop_id) ON DELETE CASCADE
);
ALTER TABLE public.glur_prebatch_recipes ADD CONSTRAINT glur_prebatch_recipes_id_shop_unique UNIQUE(id,shop_id);
CREATE TABLE public.glur_prebatch_nonstock_ingredients (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 shop_id uuid NOT NULL REFERENCES public.glur_shops(id),
 recipe_id uuid NOT NULL,
 name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 150),
 quantity numeric NOT NULL CHECK (quantity > 0),
 unit text NOT NULL CHECK (length(btrim(unit)) BETWEEN 1 AND 30),
 cost_per_unit numeric NOT NULL DEFAULT 0 CHECK (cost_per_unit = 0),
 CONSTRAINT prebatch_nonstock_parent FOREIGN KEY(recipe_id,shop_id)
 REFERENCES public.glur_prebatch_recipes(id,shop_id) ON DELETE CASCADE
);
CREATE INDEX recipe_nonstock_lookup ON public.glur_recipe_nonstock_ingredients(shop_id,recipe_id);
CREATE INDEX prebatch_nonstock_lookup ON public.glur_prebatch_nonstock_ingredients(shop_id,recipe_id);
ALTER TABLE public.glur_recipe_nonstock_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.glur_prebatch_nonstock_ingredients ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.glur_recipe_nonstock_ingredients FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.glur_prebatch_nonstock_ingredients FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,DELETE ON public.glur_recipe_nonstock_ingredients TO authenticated;
GRANT SELECT,INSERT,DELETE ON public.glur_prebatch_nonstock_ingredients TO authenticated;
CREATE POLICY recipe_ns_read ON public.glur_recipe_nonstock_ingredients FOR SELECT TO authenticated USING (
 glur_stock_allowed(shop_id,'recipes_view') OR glur_stock_allowed(shop_id,'recipes_edit') OR glur_stock_allowed(shop_id,'recipes_delete')
);
CREATE POLICY recipe_ns_insert ON public.glur_recipe_nonstock_ingredients FOR INSERT TO authenticated WITH CHECK (
 glur_stock_allowed(shop_id,'recipes_create') OR glur_stock_allowed(shop_id,'recipes_edit')
);
CREATE POLICY recipe_ns_delete ON public.glur_recipe_nonstock_ingredients FOR DELETE TO authenticated USING (
 glur_stock_allowed(shop_id,'recipes_edit') OR glur_stock_allowed(shop_id,'recipes_delete')
);
CREATE POLICY prebatch_ns_read ON public.glur_prebatch_nonstock_ingredients FOR SELECT TO authenticated USING (
 EXISTS(SELECT 1 FROM public.glur_members m WHERE m.shop_id=glur_prebatch_nonstock_ingredients.shop_id AND m.user_id=(SELECT auth.uid()))
);
CREATE POLICY prebatch_ns_insert ON public.glur_prebatch_nonstock_ingredients FOR INSERT TO authenticated WITH CHECK (
 EXISTS(SELECT 1 FROM public.glur_members m WHERE m.shop_id=glur_prebatch_nonstock_ingredients.shop_id AND m.user_id=(SELECT auth.uid()) AND m.role IN ('owner','manager'))
);
CREATE POLICY prebatch_ns_delete ON public.glur_prebatch_nonstock_ingredients FOR DELETE TO authenticated USING (
 EXISTS(SELECT 1 FROM public.glur_members m WHERE m.shop_id=glur_prebatch_nonstock_ingredients.shop_id AND m.user_id=(SELECT auth.uid()) AND m.role IN ('owner','manager'))
);
COMMIT;
