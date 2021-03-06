(*** MODULES *****************************************************************)
module C = Cache
module F = Format
module L = List
module O = Overlap
module R = Rule
module A = Analytics
module S = Settings
module St = Strategy
module Logic = Settings.Logic
module T = Term
module Expr = Constrained.Expr
module Lit = Constrained.Literal
module Lits = Constrained.Literals
module CEq = Constrained.Equality

(*** OPENS *******************************************************************)
open Prelude
open Settings

(*** TYPES *******************************************************************)
type state = {
  context : Logic.context;
  equations : Lit.t list;
  settings  : Settings.t;
  heuristic : Settings.heuristic
}

(*** EXCEPTIONS **************************************************************)
exception Success of Lit.t list

(*** GLOBALS *****************************************************************)
(*** FUNCTIONS ***************************************************************)
let (<<=>>) = Logic.(<<=>>)

let make_state c es s h = {
  context = c;
  equations = es;
  settings = s;
  heuristic = h
}

let update_state s es = { s with
  equations = es;
}

let debug s d = s.settings.debug >= d

let constraints s =
  match s.heuristic.strategy with
  | [] -> failwith "no constraints found"
  | (_, cs, _, _, _) :: _ -> cs
;;

let max_constraints s =
 match s.heuristic.strategy with
  | [] -> failwith "no max constraints found"
  | (_, _, ms, _, _) :: _ -> ms
;;

(* shorthands for settings *)
let termination_strategy s = 
  match s.heuristic.strategy with 
  | [] -> failwith "no termination strategy found"
  | (s, _, _, _, _) :: _ -> s
;;

let flatten t = Term.flatten (Signature.ac_symbols ()) t
let unflatten t = Term.flatten (Signature.ac_symbols ()) t

let normalize (s,t) =
  let s',t' = flatten s, flatten t in
  let s', t' = Variant.normalize_rule (s', t') in
  let uv = unflatten s', unflatten t' in
  uv
;;

let print_list = Lit.print_list

let set_iteration_stats s =
  let aa = s.equations in
  let i = !A.iterations in
  A.iterations := i + 1;
  A.equalities := List.length aa;
  A.set_time_mem ();
  A.eq_counts := !A.equalities :: !(A.eq_counts);
  if debug s 1 then
    F.printf "Start iteration %i with %i equations:\n %a\n%!"
      !A.iterations !A.equalities print_list aa
;;

(* OVERLAPS *)
let overlaps s rr =
  let cps1 = [Lit.overlaps_on rl1 rl2 | rl1 <- rr; rl2 <- rr] in
  let cps2 = [Lit.overlaps_on_below_root rl2 rl1 | rl1 <- rr; rl2 <- rr] in
  let cps = List.flatten (cps1 @ cps2) in
  if debug s 2 then
    Format.printf "CPs:\n%a\n" print_list cps;
  cps
;;

let overlaps s = A.take_time A.t_overlap (overlaps s)

let rewrite s ee rr =
  List.flatten [Lit.nf s.context l rr | l <- ee]
;;

(* find k maximal TRSs *)
let (<|>) = Logic.(<|>)
let (!!) = Logic.(!!)

let c_maxcomp k ctx cc =
  let oriented ((l,r), v) = Format.printf "orient %a %a\n" Term.print l Term.print r; v <|> (C.find_rule (r,l)) in
  L.iter (fun ((l,r),_, v) ->
    if l > r then Logic.assert_weighted (oriented ((l,r),v)) k) cc
;;

let search_constraints s (ccl, ccsymlvs) =
  let assert_c = function
    | S.Empty -> ()
    | _ -> Format.printf "unsupported search_constraints\n%!"
  in L.iter assert_c (constraints s);
  let assert_mc = function
    | S.Oriented -> c_maxcomp 1 s ccsymlvs
    | _ -> Format.printf "unsupported max search_constraints\n%!"
  in L.iter assert_mc (max_constraints s)
;;

let bootstrap_constraints j ctx rs =
  Logic.big_and ctx [ v <<=>> (Crpo.gt (ctx, 0) s t c) | (s,t), c, v <- rs ]
;;

let max_k s =
  let ctx, cc = s.context, s.equations in
  let k = s.heuristic.k !(A.iterations) in
  let cc_eq = [ Lit.terms n | n <- cc ] in
  let cc_symm = [n | n <- Lits.symmetric cc] in 
  let cc_symml = [Lit.terms c | c <- cc_symm] in
  L.iter (fun n -> ignore (C.store_rule_var (~assert_rule:false) ctx n)) cc_symml;
  let cc_symm_vars = [n, C.find_rule (Lit.terms n) | n <- cc_symm] in
  let cc_symml_vars = [Lit.terms n, Lit.constr n, v | n,v <- cc_symm_vars] in
  if debug s 2 then F.printf "K = %i\n%!" k;
  let rec max_k acc ctx n =
    if debug s 2 then F.printf " ... n = %i\n%!" n;
    if n = 0 then L.rev acc (* return TRSs in sequence of generation *)
    else
      if A.take_time A.t_sat Logic.max_sat ctx then (
        let m = Logic.get_model ctx in
        let c = Logic.get_cost ctx m in
        let add_rule (n,v) rls = if Logic.eval m v then (n,v) :: rls else rls in
        let rr = L.fold_right add_rule cc_symm_vars []  in
        (*let order = Crpo.decode 0 m strat in*)
        Logic.require (!! (Logic.big_and ctx [ v | _,v <- rr ]));
        max_k ((L.map fst rr, c) :: acc) ctx (n-1))
      else acc
   in
   (*A.take_time A.t_orient_constr (St.assert_constraints strat 0 ctx) cc_symml;*)
   Logic.push ctx;
   Logic.require (bootstrap_constraints 0 ctx cc_symml_vars);
   Format.printf "after bootstrap\n%!";
   search_constraints s (cc_eq, cc_symml_vars);
   let trss = max_k [] ctx k in
   Logic.pop ctx;
   trss
;;

let succeeds s rr (cps, cps_rew) =
  if cps_rew = [] then true else false
;;

let rec phi s =
  set_iteration_stats s;
  let i = !A.iterations in
  
  let process (j, s) (rr_lits, c) =
    if debug s 2 then
      Format.printf "process TRS %i-%i: %a\n%!" i j print_list rr_lits;
    let aa = s.equations in
    (*let irred, red = rewrite rr aa in *)
    let cps = overlaps s rr_lits in
    let cps' = rewrite s cps rr_lits in
    let cps'' = (*select*) cps' in
    if succeeds s rr_lits (cps, cps') then
      raise (Success rr_lits)
    else
       let s' = update_state s (cps'' @ aa) in
       (j+1, s')
  in
  try
    let rrs = max_k s in
    if rrs = [] then failwith "no TRS found";
    let _, s' = L.fold_left process (0, s) rrs in
    phi s'
  with Success rr -> Format.printf "yay!\n"; (SAT, Completion [])
;;

let check_sat state ces =
  let check_sat l =
    let c, cl = Lit.constr l, Lit.log_constr l in
    assert (Expr.is_sat state.context cl)
  in
  List.iter check_sat ces
;;


let complete (settings, heuristic) ces =
  let ctx = Logic.mk_context () in
  let ces = [Constrained.Literal.of_equation ctx (e, c) | e, c <- ces] in
  let start = Unix.gettimeofday () in
  let s = make_state ctx ces settings heuristic in
  check_sat s ces;
  let syms = Rules.signature [ Lit.terms n | n <- ces ] in
  let _ = Crpo.init (ctx,0) syms in (* FIXME: crpo now fixed *)
  let res = phi s in
  A.t_process := !(A.t_process) +. (Unix.gettimeofday () -. start);
  Logic.del_context ctx;
  res
;;