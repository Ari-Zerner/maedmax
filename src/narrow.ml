(*** MODULES *****************************************************************)
module L = List
module T = Term
module R = Rule
module S = Settings
(*** MODULES *****************************************************************)
open Settings

(*** GLOBALS *****************************************************************)
let settings = S.default

(*** FUNCTIONS ***************************************************************)
let debug _ = !(settings.d) >= 1

let pstr = function
    [] -> "e"
  | p -> L.fold_left (fun s i -> s ^ (string_of_int i)) "" p
;;

let rec nf rr (s,ps) =
  let nf_at_with p (t,pt) (l,r) =
    try
      let u = Rewriting.step_at_with t p (l,r) in
      let pt' = L.filter (fun q -> not (Listx.is_prefix p q)) pt in
      let pu = Listx.unique (pt' @ [ p @ q | q <- T.function_positions r ]) in
      (u,pu)
    with _ -> (t,pt)
  in
  let nf_at t_pt p = List.fold_left (nf_at_with p) t_pt rr in
  let s_ps' = List.fold_left nf_at (s,ps) (T.function_positions s) in
  if s_ps' = (s,ps) then (s,ps) else nf rr s_ps'
;;

let nf2 rr ((s,t),(ps,pt)) =
  let s',ps' = nf rr (s,ps) in
  let t',pt' = nf rr (t,pt) in
  ((s',t'),(ps',pt'))
;;

(* basic narrowing *)
let narrow_forward_at_with rr ((s,t),(ps,pt)) p (l,r) =
  let s_p = T.subterm_at p s in
  try
    let subst = T.substitute (Subst.mgu s_p l) in
    let s' = T.replace (subst s) (subst r) p in
    let ps' = L.filter (fun q -> not (Listx.is_prefix p q)) ps in
    let ps' = Listx.unique (ps' @ [ p @ q | q <- T.function_positions r ]) in
    let st', keep_dir = Variant.normalize_rule_dir (s',subst t) in
    let pst = if keep_dir then (ps',pt) else (pt,ps') in
    if debug () then
      Format.printf "forward narrow (%a,%a) with %a at %s to (%a,%a)\n%!"
        T.print s T.print t
        R.print (l,r) (pstr p)
        T.print (fst st') T.print (snd st');
    let uv,ps_uv = nf2 rr (st',pst) in
    if debug () then
      Format.printf "rewrite to (%a,%a)\n%!" T.print (fst uv) T.print (snd uv);
    [(uv,ps_uv)]
  with _ -> []
;;

let narrow_at rr st p =
  L.concat (L.map (fun rl -> narrow_forward_at_with rr st p (R.rename rl)) rr)
;;

let merge ((s,t),(ps,pt)) ((s',t'),(ps',pt')) =
  if R.variant (s,t) (s',t') then
    (s,t),(Listx.unique (ps@ps'), Listx.unique (pt@pt'))
  else if R.variant (t,s) (s',t') then
    (s',t'),(Listx.unique (pt@ps'), Listx.unique (ps@pt'))
  else ((s',t'),(ps',pt'))
;;

let sym_variant ((s,t),_) (st',_) = R.variant (t,s) st' || R.variant (s,t) st'

let rec add st = function
    [] -> [st]
  | st' :: gs when sym_variant st st' -> (merge st st') :: gs  
  | st' :: gs -> st' :: (add st gs)
;;

let unique = L.fold_left (fun all g -> add g all) []

let narrow rr ((s,t),(ps,pt)) =
  L.concat ((L.map (narrow_at rr ((s,t),(ps,pt))) ps) @
  (L.map (narrow_at rr ((t,s),(pt,ps))) pt))
;;

let decide rr ee ord gs =
  let bot = match ord#bot with Some b -> b | _ -> 100 in
  let patch (l,r) = 
    let vs = Listset.diff (T.variables r) (T.variables l) in
    R.substitute [ v, T.F (bot,[]) | v <- vs ] (l,r)
  in
  let ee' = L.map patch ee in
  let var_add es n = if not (L.exists (R.variant n) es) then n::es else es in
  let ee' = L.fold_left var_add [] ee' in
  let ee' = L.filter (fun e -> not (L.exists (fun e' -> R.is_proper_instance e e') ee')) ee' in
  if debug () then (
    Format.printf "EE:\n%a\n%!" Rules.print ee');
  let rr' = rr @ ee' in

  let rec decide_by_narrowing all gs =
  if debug () then (
    Format.printf "start decide_by_narrowing iteration\n%!";
    let psstr ps =
      "{" ^ (L.fold_left (fun s p -> s ^ ", " ^ (pstr p)) "" ps) ^ "}"
    in
    L.iter (fun ((s,t),(ps,pt)) ->
      Format.printf "  (%a,%a) (%s,%s)\n%!" T.print s T.print t
        (psstr ps) (psstr pt)) gs;
    Format.printf "all:\n";
    L.iter (fun ((s,t),(ps,pt)) ->
      Format.printf "  (%a,%a) (%s,%s)\n%!" T.print s T.print t
        (psstr ps) (psstr pt)) all);
  let unifiable ((s,t),_) = Subst.unifiable s t in
  if L.exists unifiable gs then (
    if debug () then
      Format.printf "UNSAT, found unifiable equation\n%!";
    Some (S.UNSAT, S.Proof (fst (L.find unifiable gs),([],[]),[])))
  else if L.for_all (fun (_,(ps,pt)) -> ps @ pt = []) gs then (
    Some (S.SAT, S.GroundCompletion (rr,ee,ord)))
  else
    let all' = unique (all @ gs) in
    let remove_gs ((st,(ps,pt)) as np) =
      try
        let _,(ps',pt') = L.find (fun (st',_) -> R.variant st' st) all' in
        (st,(Listset.diff ps ps', Listset.diff pt pt'))
      with Not_found -> np
    in
    let gs' = unique (L.concat (L.map (narrow rr') gs)) in
    let gs' = L.map remove_gs gs' in
    decide_by_narrowing all' (Listx.unique gs')
  in
  let gs = [(s,t), (T.function_positions s,T.function_positions t)|s,t <- gs] in
  decide_by_narrowing [] gs
;;
