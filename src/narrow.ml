(*** MODULES *****************************************************************)
module L = List
module T = Term
module R = Rule
module S = Settings
module Sub = Term.Sub
module Lit = Literal

(*** MODULES *****************************************************************)
open Settings

(*** EXCEPTIONS **************************************************************)
exception Too_large

(*** GLOBALS *****************************************************************)
let settings = S.default

let heuristic = ref S.default_heuristic

(*** FUNCTIONS ***************************************************************)
let debug settings = settings.debug >= 1

let sat_allowed _ = !heuristic.mode <> OnlyUNSAT

let unsat_allowed _ = !heuristic.mode <> OnlySAT

let pstr = function
    [] -> "e"
  | p -> L.fold_left (fun s i -> s ^ (string_of_int i)) "" p
;;

(* remove all positions >= p from ps and add pq for q a fun pos in r *)
let propagate_basic_pos p ps r =
  let ps' = Hashset.filter2new (fun q -> not (Listx.is_prefix p q)) ps in
  let ps_new = Hashset.of_list [ p @ q | q <- T.function_positions r ] in
  Hashset.add_all ps_new ps'
;;

let rec nf rr ((s, _, _) as spr) =
  let nf_at_with p (t, pt, rt) ((l,r),_) =
    try
      let u, sigma = Rewriting.step_at_with t p (l, r) in
      (u, propagate_basic_pos p pt r, ((l,r), p, sigma) :: rt)
    with _ -> (t,pt, rt)
  in
  let nf_at t_pt p = List.fold_left (nf_at_with p) t_pt rr in
  let ((s', _, _) as spr') = List.fold_left nf_at spr (T.function_positions s) in
  if s' = s then spr else nf rr spr'
;;

(* rewriting to normal form for both terms *)
let nf2 rr ((s,t),(ps,pt)) =
  let s',ps',rs = nf rr (s,ps,[]) in
  let t',pt',rt = nf rr (t,pt,[]) in
  ((s',t'),(ps',pt'), (rs, rt))
;;

(* basic narrowing *)
let narrow_forward_at_with settings rr (g,(ps,pt)) p ((l,r), rl_lit) =
  let s, t = Lit.terms g in
  let s_p = T.subterm_at p s in
  try
    let sigma = Subst.mgu s_p l in
    let subst = T.substitute sigma in
    let s' = T.replace (subst s) (subst r) p in
    let ps' = propagate_basic_pos p ps r in
    let st', keep_dir = (*Variant.normalize_rule_dir*) (s',subst t), true in
    if Rule.size st' > (*!(settings.size_bound_goals)*) 200 then (
      heuristic := { !heuristic with mode = OnlyUNSAT };
      raise Too_large);
    let goal = Lit.make_neg_axiom in
    let g_st' = goal st' in
    (*if g_st'.id mod 100 = 0 then Format.printf "created anniversary node %d\n%!" g_st'.id;*)
    (if !(Settings.do_proof) = Some TPTP then
      Lit.LightTrace.add_overlap g_st' (rl_lit, g)
    else if !(Settings.do_proof) = Some CPF then
      Trace.add_overlap st' ((l,r), p, (s,t), sigma));
    let pst = if keep_dir then (ps',pt) else (pt,ps') in
    if debug settings then
      Format.printf "forward narrow (%a,%a) with %a at %s to (%a,%a) %d\n%!"
        T.print s T.print t
        R.print (l,r) (pstr p)
        T.print (fst st') T.print (snd st')
        (R.size st');
    [g_st', pst]
    (*let uv, ps_uv, rs_uv = nf2 rr (st',pst) in
    if debug settings then
      Format.printf "rewrite to (%a,%a)\n%!" T.print (fst uv) T.print (snd uv);
    let g_uv = goal uv in
    (if !(Settings.do_proof) = Some TPTP then
      let rs = [r | r, _, _ <- fst rs_uv], [r | r, _, _ <- snd rs_uv] in
      Lit.LightTrace.add_rewrite g_st' g_uv rs
    else if !(Settings.do_proof) = Some CPF then
      Trace.add_rewrite st' uv rs_uv);
    [g_uv, ps_uv]*)
  with _ -> []
;;

let narrow_at settings rr st p =
  let forward = narrow_forward_at_with settings in
  L.concat (L.map (fun (rl, l) -> forward rr st p (R.rename rl, l)) rr)
;;

let merge (g,(ps,pt)) (g',(ps',pt')) =
  let s,t = Lit.terms g in
  let s',t' = Lit.terms g' in
  if (s,t) = (s',t') then
    g,(Hashset.add_all ps ps', Hashset.add_all pt pt')
  else if (t,s) = (s',t') then
    g',(Hashset.add_all pt ps', Hashset.add_all ps pt')
  else (g',(ps',pt'))
;;

(*let sym_variant ((s,t),_) (st',_) = R.variant (t,s) st' || R.variant (s,t) st'*)
let sym_variant (s,t) st' = (t,s) = st' || (s,t) = st'

let rec add g = function
    [] -> [g]
  | g' :: gs when sym_variant (fst g).terms (fst g').terms -> (merge g g') :: gs
  | g' :: gs -> g' :: (add g gs)
;;

let unique_add gs_new gs =
  (* takes too long, and for examples like COL06*-1 unique does not change*)
  if List.length gs > 1000 || List.length gs_new > 1000 then List.rev_append gs_new gs
  else L.fold_left (fun all g -> add g all) gs gs_new
;;

let unique gs =
  if List.length gs > 1000 then gs (* takes too long ...*)
  else L.fold_left (fun all g -> add g all) [] gs
;;

let narrow settings rr (g,(ps,pt)) =
  let narrow x px = Hashset.map_to_list (narrow_at settings rr x) px in
  L.concat ((narrow (g,(ps,pt)) ps) @ (narrow (Lit.flip g,(pt,ps)) pt))
;;

let decide settings (rr, rew) ee ord gs h =
  heuristic := h;
  let bot = T.F ((match ord#bot with Some b -> b | _ -> 100), []) in
  let patch (l, r) = 
    let vs = Listset.diff (T.variables r) (T.variables l) in
    let sub = List.fold_left (fun s x -> Sub.add x bot s) Sub.empty vs in
    R.substitute sub (l, r)
  in
  let ee' = L.map patch ee in
  let var_add es n = if not (L.exists (R.variant n) es) then n::es else es in
  let ee' = L.fold_left var_add [] ee' in
  let ee' = L.filter
    (fun e -> not (L.exists (fun e' -> R.is_proper_instance e e') ee')) ee' in
  if debug settings then (
    Format.printf "EE:\n%a\n%!" Rules.print ee';
    Format.printf "SAT allowed:%B\n%!" (sat_allowed ()));
  let rr' = [r, Lit.make_axiom r | r <- rr @ ee'] in
  let rec decide_by_narrowing acc gs =
    let unifiable (g,_) = let (s,t) = g.terms in Subst.unifiable s t in
    let both_empty (ps,pt) = Hashset.is_empty ps && Hashset.is_empty pt in
    if L.exists unifiable gs then (
      if debug settings then
        Format.printf "UNSAT, found unifiable equation\n%!";
      if unsat_allowed () then
        let g = fst (L.find unifiable gs) in
        Some (S.UNSAT, S.Proof (g.terms, ([],[]), fst g.terms, Sub.empty))
      else raise Backtrack
      )
    else if L.for_all (fun (_,ps) -> both_empty ps) gs && sat_allowed () then (
      Some (S.SAT, S.GroundCompletion (rr,ee,ord)))
    else
      let acc' = unique_add gs acc in
      let aux = L.concat (L.map (narrow settings rr') gs) in
      let gs' = unique aux in
      decide_by_narrowing acc' gs'
    in
  let poss t = Hashset.of_list (T.function_positions t) in
  let gs = [Lit.make_neg_axiom (s, t), (poss s, poss t) | s,t <- gs] in
  decide_by_narrowing [] gs
;;

let decide_goals settings rr ee o ic = decide settings rr ee o settings.gs ic
