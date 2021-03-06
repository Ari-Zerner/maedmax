(*** MODULES *****************************************************************)
module L = List
module C = Cache
module F = Format
module Sig = Signature
module Logic = Settings.Logic

(*** OPENS *******************************************************************)
open Term
open Logic
open Settings

(*** TYPES *******************************************************************)
type flags = {
 af : bool ref 
}

(*** GLOBALS *****************************************************************)
(* settings for LPO *)
let flags = { af = ref false }
(* signature *)
let funs = ref []
(* map function symbol and strategy stage to variable for precedence *)
let precedence : (int * Sig.sym, Logic.t) Hashtbl.t = Hashtbl.create 32
(* map function symbol and strategy stage to variable expressing whether
   argument filtering for symbol is list *)
let af_is_list : (int * Sig.sym, Logic.t) Hashtbl.t = Hashtbl.create 32
(* variable whether argument position for symbol is contained in filtering *)
let af_arg : ((int * Sig.sym) * int, Logic.t) Hashtbl.t = Hashtbl.create 64

(* cache results of comparison *)
let gt_encodings : (int * Rule.t, Logic.t) Hashtbl.t = Hashtbl.create 512
let ge_encodings : (int * Rule.t, Logic.t) Hashtbl.t = Hashtbl.create 512
let eq_encodings : (int * Rule.t, Logic.t) Hashtbl.t = Hashtbl.create 512

(*** FUNCTIONS ***************************************************************)
let (<>>) = Int.(<>>)

let (<>=>) = Int.(<>=>)

let name = Sig.get_fun_name

let set_af _ = flags.af := true

let (<.>) f g x = f (g x)

let cache ht f k =
 try Hashtbl.find ht k with Not_found -> 
 let v = f k in Hashtbl.add ht k v; v
;;

let rec emb_geq s t = 
  match s, t with 
  | V x, V y when x = y -> true
  | F (f, ss), (F (g, ts) as t) when f = g ->
      L.exists (fun si -> emb_geq si t) ss || 
      L.for_all2 (fun si ti -> emb_geq si ti) ss ts
  | F (f, ss), t -> 
      L.exists (fun si -> emb_geq si t) ss
  | _ -> false
;;

let emb_gt s t = s <> t && emb_geq s t

(* lpo for yices *)

let prec i f = 
  try Hashtbl.find precedence (i,f) with
  Not_found ->
    failwith ("Lpo.prec: unknown symbol " ^ (name f) ^ ", " ^ (string_of_int i))
;;

let gt (ctx,i) s t =
  let p = prec i in
  let rec ylpo_gt s t =
    let helper (i,(s,t)) =
      if emb_gt s t then mk_true ctx
      else if not (Rule.is_rule (s,t)) || emb_geq t s then mk_false ctx
      else match s, t with
	      | F(f,ss), F(g,ts) ->
          let sub = big_or ctx [ ylpo_ge si t | si <- ss ] in
          if f = g then
            big_and1 (ylex ss ts :: [ ylpo_gt s ti | ti <- ts ]) <|> sub
          else
            big_and1 ((p f <>> (p g)) :: [ ylpo_gt s ti | ti <- ts ]) <|> sub
        | _ -> mk_false ctx (* variable case already covered *)
    in cache gt_encodings helper (i,(s,t))
  and ylpo_ge s t = if s = t then mk_true ctx else ylpo_gt s t
  and ylex l1 l2 = match l1, l2 with
    | s :: ss, t :: ts when s = t -> ylex ss ts
    | s :: ss, t :: ts -> ylpo_gt s t
    | [], [] -> mk_false ctx
    | _ -> mk_true ctx
  in ylpo_gt s t
;;

let ge (ctx,i) s t = if s = t then mk_true ctx else gt (ctx,i) s t

(* * ENCODING WITH ARGUMENT FILTERS * * * * * * * * * * * * * * * * * * * * * *)

let index = Listx.index

(* argument filtering for f is list *)
let af_l (ctx,k) f =
 try Hashtbl.find af_is_list (k,f) 
 with Not_found ->
  let x = mk_fresh_bool_var ctx in Hashtbl.add af_is_list (k,f) x; x
;;

(* variable returned by [af_p c f i] determines whether argument 
   filtering for [f] includes position [i] *)
let af_p (ctx,k) f i =
 try Hashtbl.find af_arg ((k,f),i)
 with Not_found ->
  let x = mk_fresh_bool_var ctx in Hashtbl.add af_arg ((k,f),i) x; x
;;

let af_n (ctx,k) f = !! (af_l (ctx,k) f)

let exists (ctx,k) f ts p =
 big_or ctx [ af_p (ctx,k) f i <&> (p ti) | i,ti <- index ts ]
;;

let forall (ctx,k) f ts p =
 big_and ctx [ af_p (ctx,k) f i <=>> (p ti) | i,ti <- index ts ]
;;

let exists2 (ctx,k) f ss ts p =
 let ps = index (L.map2 (fun a b -> a,b) ss ts) in
 big_or ctx [ af_p (ctx,k) f i <&> (p si ti) | i,(si,ti) <- ps ]
;;

let forall2 (ctx,k) f ss ts p =
 let ps = index (L.map2 (fun a b -> a,b) ss ts) in
 big_and ctx [ af_p (ctx,k) f i <=>> (p si ti) | i,(si,ti) <- ps ]
;;

let ylpo_af is_gt ((ctx,k) as c) s t =
  let af_p,af_l,af_n,prec = af_p (ctx,k), af_l (ctx,k), af_n (ctx,k), prec k in
  let rec gt s t =
    let helper (k, (s,t)) =
      match s with
        | V _-> mk_false ctx
        | F(f, ss) -> match t with
          | V x -> (exists c f ss (fun si -> gt si t)) <|>
                   (af_l f <&> (exists c f ss (fun si -> eq si t)))
          | F(g, ts) when f = g ->
            let a = big_and1 [af_l f;lex_gt f (ss,ts); forall c f ts (gt s)] in
            let b = af_l f <&> (exists c f ss (fun si -> eq si t)) in
            let c = af_n f <&> (exists2 c f ss ts gt) in
            big_or1 [a; b; c]
          | F(g, ts) ->
            let pgt = [prec f <>> (prec g); af_l f; af_l g] in
            let a = (af_n g <|> (big_and1 pgt)) <&> (forall c g ts (gt s)) in
            let b = af_n f <&> (exists c f ss (fun si -> gt si t)) in
            let c = af_l f <&> (exists c f ss (fun si -> eq si t)) in
            big_or1 [a; b; c]
    in cache gt_encodings helper (k,(s,t))
  and ge s t = 
    let helper (k,(s,t)) = (eq s t) <|> (gt s t) in
    cache ge_encodings helper (k,(s,t))
  and eq s t =
    let helper (k,(s,t)) =
      match s,t with
        | V _, _ when s = t -> mk_true ctx
        | V _, V _ -> mk_false ctx
        | V _, F(g,ts) -> af_n g <&> (exists c g ts (fun tj -> eq s tj))
        | F (f,ss), V _ -> af_n f <&> (exists c f ss (fun si -> eq si t))
        | F (f, ss), F (g, ts) when f=g -> forall2 c f ss ts eq
        | F (f, ss), F (g, ts) -> ((af_n g) <&> (exists c g ts (eq s))) <|>
                               (af_n f <&> (exists c f ss (fun si -> eq si t))) 
    in cache eq_encodings helper (k,(s,t))
  and lex_gt ?(i = 0) f = function
    | s :: ss, t :: ts -> ((af_p f i) <&> (gt s t)) <|>
               (((!! (af_p f i)) <|> (eq s t)) <&> (lex_gt ~i:(i+1) f (ss,ts)))
    | [], [] -> mk_false ctx
    | _ -> failwith "different lengths in lex"
  in if is_gt then gt s t else ge s t
;;

let gt_af = ylpo_af true

let ge_af (ctx,k) s t = ylpo_af false (ctx,k) s t

(* * OVERALL ENCODING * * * * * * * * * * * * * * * * * * * * * * * * * * * * *)

let make_fun_vars ctx k fs =
 let add f =
   let ki = string_of_int k in
   Hashtbl.add precedence (k,f) (Int.mk_var ctx ("lpo" ^ (name f) ^ "-" ^ ki))
 in L.iter add fs
;;

let init s ctx k =
  let fs = Rules.signature (s.gs @ [ r.terms | r <- s.norm @ s.axioms]) in
  funs := fs;
  Hashtbl.clear precedence;
  let fs' = L.map fst fs in
  make_fun_vars ctx k fs';
  let bnd_0 = Int.mk_zero ctx in
  let bnd_n = Int.mk_num ctx (L.length fs') in
  let bounds f = let p = prec k f in (p <>=> bnd_0) <&> (bnd_n <>=> p) in
  (* FIXME causes stack overflow with too large signatures *)
  let total_prec =
    if List.length fs > 400 then mk_true ctx
    else
      let ps = [ f,g | f <- fs'; g <- fs'; f <> g ] in
      let p = prec k in
      big_and ctx [ !! (p f <=> (p g)) | f, g <- ps ]
  in
  let constr = big_and1 (total_prec :: [ bounds f | f <- fs' ]) in
  let rec gt = function
    | f :: g :: fs -> (prec k f <>> prec k g) <&> gt (g :: fs)
    | _ -> mk_true ctx
  in
  match s.order_params with
  | Some ps -> List.fold_left (fun c prec -> gt prec <&> c) constr ps.precedence
  | _ -> constr
;;

let init_af s ctx k =
  let c = init s ctx k in
  let fs = Rules.signature (s.gs @ [ r.terms | r <- s.norm @ s.axioms]) in
  let af (f,a) =
    let p = af_p (ctx,k) f in
    let is = Listx.interval 0 (a-1) in 
    let only i = big_and1 (p i :: [ !! (p j) | j <- is; j <> i ]) in
    big_or1 (af_l (ctx,k) f :: [ only i | i <- is ])
  in
  big_and1 (c :: [af f | f <- fs ])
;;

let init settings ctx = (if !(flags.af) then init_af else init) settings ctx

let decode_prec_aux k m =
 let add (k',f) x p =
   if k <> k' then p
   else (
     try
       let v = Int.eval m x in
       Hashtbl.add p f v; p
     with _ -> p)
 in Hashtbl.fold add precedence (Hashtbl.create 16)
;;

let eval_prec k m =
 let prec = Hashtbl.find (decode_prec_aux k m) in
 List.sort (fun (_, p) (_,q) -> p - q) [ (f,a), prec f | f,a <- !funs ]
;;

let prec_to_string = function
    [] -> ""
  | ((f,_),p) :: fp ->
    let s = "LPO \n " ^ (name f) in
    List.fold_left (fun s ((f,_),_) -> s ^ " < " ^ (name f)) s fp;
;;

let print_prec p = Format.printf "%s\n%!" (prec_to_string p)

let decode_print k m = print_prec (eval_prec k m)

let decode_print_af k m =
 let dps = [ rl | rl,v <- C.get_all_strict 1; eval m v ] in
 let rls = [ rl | rl,v <- C.get_all_strict 0; eval m v ] in
 decode_print k m;
 let dec (f,a) =
  try
  F.printf " pi(%s)=" (name f); 
  let af_p f i = Hashtbl.find af_arg ((k,f),i) in
  let args = [ i | i <- Listx.interval 0 (a-1); eval m (af_p f i) ] in
  if eval m (Hashtbl.find af_is_list (k,f)) then (
   F.printf "["; Listx.print (fun fmt -> F.fprintf fmt "%i") ", " args;
   F.printf "]")
  else Listx.print (fun fmt -> F.fprintf fmt "%i") ", " args;
  F.printf "@\n"
  with Not_found -> failwith "decode_af: Not_found"
 in
 F.printf "argument filtering: @\n"; 
 L.iter dec [ (f,a) | (f,a) <- !funs; L.mem f (Rules.functions (dps @ rls))]
;;

let decode_term_gt' tp add_syms =
  let sz_sig = Hashtbl.length tp in
  List.iter (fun (p,f) -> Hashtbl.add tp f p) (Listx.ix ~i:sz_sig add_syms);
 let prec = Hashtbl.find tp in
 let rec gt s t =
  if Term.is_subterm s t then false
  else if Term.is_subterm t s then true
  else
   match s,t with
    | V _, _
    | _, V _  -> false (* no subterm *)
    | F(f,ss), F(g,ts) ->
      let sub_gt = L.exists (fun si -> (gt si t) || (si = t)) ss in
      if f <> g then
       sub_gt || (prec f > prec g && L.for_all (gt s) ts)
      else (
       let lex (gt_lex,ge) (si,ti) = gt_lex || (ge && gt si ti), ge && si=ti in
       let lex_gt = fst (L.fold_left lex (false, true) (List.combine ss ts)) in
       sub_gt || (lex_gt && L.for_all (gt s) ts))
  in gt
;;

let decode_term_gt k m = decode_term_gt' (decode_prec_aux k m)

let decode_xml prec =
  let status_prec ((f,a),p) =
    let name = Xml.Element("name", [], [Xml.PCData (name f)]) in
    let arity = Xml.Element("arity", [], [Xml.PCData (string_of_int a)]) in
    let prec = Xml.Element("precedence", [], [Xml.PCData (string_of_int p)]) in
    let lex = Xml.Element("lex", [], []) in
    Xml.Element("statusPrecedenceEntry", [], [ name; arity; prec; lex] )
  in
  let w0 = Xml.Element("w0", [], [Xml.PCData "1"]) in
  let pw = Xml.Element("statusPrecedence", [], [ status_prec f | f <- prec ]) in
  Xml.Element("pathOrder", [], [ w0; pw ] )
;;

let print_params = function
    [] -> ()
  | ((f,_),p) :: fp ->
    Format.printf "-t LPO ";
    if fp <> [] then (
      Format.printf "--precedence=\"%s" (name f);
      List.iter (fun ((f,_),_) -> Format.printf "<%s" (name f)) fp;
      Format.printf "\"\n%!"
      )
;;

let encode i preclist ctx =
 let add ((f,_), p) = (prec i f <=> (Int.mk_num ctx p)) in
 Logic.big_and ctx (List.map add preclist)
;;

let decode k m =
  let gt = decode_term_gt k m in
  let cmp c d = if gt [] (Term.F(c,[])) (Term.F(d,[])) then d else c in
  let bot =  match [ c | c,a <- !funs; a = 0] with
      [] -> None
    | c :: cs -> Some (List.fold_left cmp c cs)
  in
  let prec = eval_prec k m in
  object
    method bot = bot
    method gt = gt []
    method gt_extend_sig = gt
    method smt_encode = encode k prec
    method to_string = prec_to_string prec
    method print = fun _ -> print_prec prec
    method to_xml = decode_xml prec
    method print_params = fun _ -> print_params prec
  end
;;

let cond_gt i ctx conds s t =
  let p = prec i in
  let rec gt s t =
    if L.mem (s,t) conds || (emb_gt s t) then mk_true ctx
    else if emb_geq t s then mk_false ctx
    else match s, t with
	    | F(f,ss), F(g,ts) ->
        let sub = big_or ctx [ ylpo_ge si t | si <- ss ] in
        if f = g then
          big_and1 (ylex ss ts :: [ gt s ti | ti <- ts ]) <|> sub
        else
          big_and1 ((p f <>> (p g)) :: [ gt s ti | ti <- ts ]) <|> sub
      | _, F(g,ts) -> big_and ctx ([p f <>> (p g) | f,_ <- !funs; f <> g ] @
                                   (L.map (gt s) ts)) (* special hack *)
        | _ -> mk_false ctx (* variable case already covered *)
  and ylpo_ge s t = if s = t then mk_true ctx else gt s t
  and ylex l1 l2 = match l1, l2 with
    | s :: ss, t :: ts when s = t -> ylex ss ts
    | s :: ss, t :: ts -> gt s t
    | [], [] -> mk_false ctx
    | _ -> mk_true ctx
  in gt s t
;;

let clear () =
 Hashtbl.clear precedence; 
 Hashtbl.clear af_is_list; 
 Hashtbl.clear af_arg; 
 Hashtbl.clear gt_encodings; 
 Hashtbl.clear ge_encodings; 
 Hashtbl.clear eq_encodings
;;

