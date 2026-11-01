
-- Import recipes from TEST to LIVE by exact ingredient name and unit.
-- Public invoker delegates to a private, developer-checked transaction.
create or replace function glur_private.import_test_recipe(p_kind text,p_recipe_id uuid,p_apply boolean default false,p_replace boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 src constant uuid := 'e15ec9b2-3c5a-48a0-a927-cdb0c2a8d6af';
 dst constant uuid := 'bdd83213-8d38-42d7-bd35-835506dc25ac';
 rt text; it text; nt text; recipe jsonb; r record; candidate record;
 mapped jsonb := '[]'; nonstock jsonb := '[]'; issues jsonb := '[]'; names jsonb := '[]';
 matches integer; target uuid; existing uuid; out_id uuid; new_id uuid; count_items integer := 0;
begin
 if auth.uid() is null or not glur_private.is_developer(src) or not glur_private.is_developer(dst) then raise exception 'GLUR_DEVELOPER_ONLY'; end if;
 if p_kind not in ('cocktail','prebatch') or p_kind is null then raise exception 'Invalid recipe kind'; end if;
 if coalesce(p_apply,false) then
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('glur_recipe_import_live',0));
  lock table public.glur_stock,public.glur_cost_catalog,public.glur_recipes,public.glur_recipe_ingredients,public.glur_recipe_nonstock_ingredients,public.glur_prebatch_recipes,public.glur_prebatch_ingredients,public.glur_prebatch_nonstock_ingredients in share row exclusive mode;
 end if;
 rt:=case when p_kind='cocktail' then 'glur_recipes' else 'glur_prebatch_recipes' end;
 it:=case when p_kind='cocktail' then 'glur_recipe_ingredients' else 'glur_prebatch_ingredients' end;
 nt:=case when p_kind='cocktail' then 'glur_recipe_nonstock_ingredients' else 'glur_prebatch_nonstock_ingredients' end;
 execute format('select to_jsonb(r) from public.%I r where id=$1 and shop_id=$2',rt) into recipe using p_recipe_id,src;
 if recipe is null then raise exception 'ไม่พบสูตรใน TEST'; end if;
 execute format('select count(*),(array_agg(id))[1] from public.%I where shop_id=$1 and name=$2',rt) into matches,existing using dst,recipe->>'name';
 if matches>1 then issues:=issues||jsonb_build_array('มีสูตรชื่อซ้ำหลายรายการใน LIVE'); end if;
 for r in execute format('select i.stock_id,i.quantity,s.name,s.unit,s.is_active from public.%I i left join public.glur_stock s on s.id=i.stock_id and s.shop_id=$2 where i.recipe_id=$1 and i.shop_id=$2',it) using p_recipe_id,src loop
  count_items:=count_items+1;
  select count(*),(array_agg(s.id))[1] into matches,target from public.glur_stock s where s.shop_id=dst and s.name=r.name and s.unit=r.unit and s.is_active;
  if matches<>1 or not coalesce(r.is_active,false) or r.quantity<=0 then
   issues:=issues||jsonb_build_array('ส่วนผสม '||coalesce(r.name,'ไม่พบชื่อ')||' ('||coalesce(r.unit,'')||'): '||case when matches>1 then 'ชื่อและหน่วยซ้ำใน LIVE' else 'ต้องมีชื่อและหน่วยตรงกัน และเปิดใช้งานทั้งสองโหมด' end);
  else
   mapped:=mapped||jsonb_build_array(jsonb_build_object('stock_id',target,'quantity',r.quantity));
   names:=names||jsonb_build_array(r.name||' · '||r.quantity||' '||r.unit);
  end if;
 end loop;
 if count_items=0 then issues:=issues||jsonb_build_array('สูตรต้องมีวัตถุดิบอย่างน้อย 1 รายการ'); end if;
 for r in execute format('select name,unit,quantity from public.%I where shop_id=$1 and recipe_id=$2',nt) using src,p_recipe_id loop
  select count(*) into matches from public.glur_cost_catalog c where c.shop_id=dst and c.name=r.name and c.unit=r.unit;
  if matches<>1 or r.quantity<=0 then
   issues:=issues||jsonb_build_array('ส่วนผสมนอกสต๊อก '||r.name||' ('||r.unit||'): ต้องมีชื่อและหน่วยตรงกันเพียงรายการเดียวในคลังส่วนผสม LIVE');
  else
   select * into candidate from public.glur_cost_catalog c where c.shop_id=dst and c.name=r.name and c.unit=r.unit;
   nonstock:=nonstock||jsonb_build_array(jsonb_build_object('name',r.name,'unit',r.unit,'quantity',r.quantity,'purchase_price',candidate.purchase_price,'package_size',candidate.package_size,'cost_per_unit',0));
   names:=names||jsonb_build_array(r.name||' · '||r.quantity||' '||r.unit||' (ไม่ตัดสต๊อก)');
  end if;
 end loop;
 if p_kind='prebatch' then
  select * into candidate from public.glur_stock where shop_id=src and id=(recipe->>'output_stock_id')::uuid;
  select count(*),(array_agg(s.id))[1] into matches,out_id from public.glur_stock s where s.shop_id=dst and s.name=candidate.name and s.unit=candidate.unit and s.is_active;
  if matches<>1 or not coalesce(candidate.is_active,false) then issues:=issues||jsonb_build_array('สต๊อกผลผลิต: ต้องมีชื่อและหน่วยตรงกันเพียงรายการเดียว และเปิดใช้งานทั้งสองโหมด'); end if;
  if exists(select 1 from jsonb_array_elements(mapped) m where (m->>'stock_id')::uuid=out_id) then issues:=issues||jsonb_build_array('ผลผลิตซ้ำกับวัตถุดิบต้นทาง'); end if;
  if coalesce((recipe->>'standard_yield')::numeric,0)<=0 then issues:=issues||jsonb_build_array('กรอกผลผลิตประมาณต่อสูตรใน TEST ก่อน'); end if;
  if existing is not null and exists(select 1 from public.glur_prebatch_batches where shop_id=dst and recipe_id=existing)
   and exists(select 1 from public.glur_prebatch_recipes where id=existing and output_stock_id is distinct from out_id) then issues:=issues||jsonb_build_array('สูตร LIVE มีประวัติผลิตแล้ว จึงเปลี่ยนสต๊อกผลผลิตไม่ได้'); end if;
 end if;
 if not coalesce(p_apply,false) then
  return jsonb_build_object('name',recipe->>'name','issues',issues,'ingredients',names,'existing',existing is not null,'ready',jsonb_array_length(issues)=0);
 end if;
 if jsonb_array_length(issues)>0 then raise exception '%',issues::text; end if;
 if existing is not null and not coalesce(p_replace,false) then raise exception 'สูตรนี้มีใน LIVE แล้ว โปรดยืนยันแทนที่สูตร'; end if;
 new_id:=coalesce(existing,gen_random_uuid());
 if p_kind='cocktail' then
  insert into public.glur_recipes(id,shop_id,name,selling_price,category,description,method,technique,glassware,garnish,notes,is_active)
   values(new_id,dst,recipe->>'name',(recipe->>'selling_price')::numeric,recipe->>'category',recipe->>'description',recipe->>'method',recipe->>'technique',recipe->>'glassware',recipe->>'garnish',recipe->>'notes',true)
   on conflict(id) do update set name=excluded.name,selling_price=excluded.selling_price,category=excluded.category,description=excluded.description,method=excluded.method,technique=excluded.technique,glassware=excluded.glassware,garnish=excluded.garnish,notes=excluded.notes,is_active=true;
 else
  insert into public.glur_prebatch_recipes(id,shop_id,name,output_stock_id,notes,standard_yield,created_by)
   values(new_id,dst,recipe->>'name',out_id,coalesce(recipe->>'notes',''),(recipe->>'standard_yield')::numeric,auth.uid())
   on conflict(id) do update set name=excluded.name,output_stock_id=excluded.output_stock_id,notes=excluded.notes,standard_yield=excluded.standard_yield;
 end if;
 execute format('delete from public.%I where shop_id=$1 and recipe_id=$2',it) using dst,new_id;
 execute format('delete from public.%I where shop_id=$1 and recipe_id=$2',nt) using dst,new_id;
 execute format('insert into public.%I(shop_id,recipe_id,stock_id,quantity) select $1,$2,(v->>''stock_id'')::uuid,(v->>''quantity'')::numeric from jsonb_array_elements($3) v',it) using dst,new_id,mapped;
 execute format('insert into public.%I(shop_id,recipe_id,name,unit,quantity,purchase_price,package_size,cost_per_unit) select $1,$2,v->>''name'',v->>''unit'',(v->>''quantity'')::numeric,(v->>''purchase_price'')::numeric,(v->>''package_size'')::numeric,(v->>''cost_per_unit'')::numeric from jsonb_array_elements($3) v',nt) using dst,new_id,nonstock;
 return jsonb_build_object('id',new_id,'name',recipe->>'name','replaced',existing is not null);
end $$;
revoke all on function glur_private.import_test_recipe(text,uuid,boolean,boolean) from public,anon;
grant execute on function glur_private.import_test_recipe(text,uuid,boolean,boolean) to authenticated;
create or replace function public.glur_import_test_recipe(p_kind text,p_recipe_id uuid,p_apply boolean default false,p_replace boolean default false)
returns jsonb language sql security invoker set search_path='' as $$
 select glur_private.import_test_recipe(p_kind,p_recipe_id,p_apply,p_replace);
$$;
revoke all on function public.glur_import_test_recipe(text,uuid,boolean,boolean) from public,anon;
grant execute on function public.glur_import_test_recipe(text,uuid,boolean,boolean) to authenticated;
