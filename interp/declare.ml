(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2018       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

(** This module is about the low-level declaration of logical objects *)

open Pp
open CErrors
open Util
open Names
open Libnames
open Globnames
open Constr
open Declarations
open Entries
open Libobject
open Lib
open Impargs
open Safe_typing
open Cooking
open Decls
open Decl_kinds

(** flag for internal message display *)
type internal_flag =
  | UserAutomaticRequest (* kernel action, a message is displayed *)
  | InternalTacticRequest  (* kernel action, no message is displayed *)
  | UserIndividualRequest   (* user action, a message is displayed *)

(** Declaration of constants and parameters *)

type constant_obj = {
  cst_decl : global_declaration option;
  (** [None] when the declaration is a side-effect and has already been defined
      in the global environment. *)
  cst_kind : logical_kind;
  cst_locl : bool;
}

type constant_declaration = Safe_typing.private_constants constant_entry * logical_kind

(* At load-time, the segment starting from the module name to the discharge *)
(* section (if Remark or Fact) is needed to access a construction *)
let load_constant i ((sp,kn), obj) =
  if Nametab.exists_cci sp then
    alreadydeclared (Id.print (basename sp) ++ str " already exists");
  let con = Global.constant_of_delta_kn kn in
  Nametab.push (Nametab.Until i) sp (ConstRef con);
  add_constant_kind con obj.cst_kind

(* Opening means making the name without its module qualification available *)
let open_constant i ((sp,kn), obj) =
  (* Never open a local definition *)
  if obj.cst_locl then ()
  else
    let con = Global.constant_of_delta_kn kn in
    Nametab.push (Nametab.Exactly i) sp (ConstRef con)

let exists_name id =
  variable_exists id || Global.exists_objlabel (Label.of_id id)

let check_exists sp =
  let id = basename sp in
  if exists_name id then alreadydeclared (Id.print id ++ str " already exists")

let cache_constant ((sp,kn), obj) =
  let id = basename sp in
  let kn' =
    match obj.cst_decl with
    | None ->
      if Global.exists_objlabel (Label.of_id (basename sp))
      then Constant.make1 kn
      else CErrors.anomaly Pp.(str"Ex seff not found: " ++ Id.print(basename sp) ++ str".")
    | Some decl ->
      let () = check_exists sp in
      Global.add_constant ~in_section:(Lib.sections_are_opened ()) id decl
  in
  assert (Constant.equal kn' (Constant.make1 kn));
  Nametab.push (Nametab.Until 1) sp (ConstRef (Constant.make1 kn));
  let cst = Global.lookup_constant kn' in
  add_section_constant (Declareops.constant_is_polymorphic cst) kn' cst.const_hyps;
  add_constant_kind (Constant.make1 kn) obj.cst_kind

let discharge_constant ((sp, kn), obj) =
  let con = Constant.make1 kn in
  let from = Global.lookup_constant con in
  let modlist = replacement_context () in
  let { abstr_ctx = hyps; abstr_subst = subst; abstr_uctx = uctx } = section_segment_of_constant con in
  let abstract = (named_of_variable_context hyps, subst, uctx) in
  let new_decl = GlobalRecipe{ from; info = { Opaqueproof.modlist; abstract}} in
  Some { obj with cst_decl = Some new_decl; }

(* Hack to reduce the size of .vo: we keep only what load/open needs *)
let dummy_constant cst = {
  cst_decl = None;
  cst_kind = cst.cst_kind;
  cst_locl = cst.cst_locl;
}

let classify_constant cst = Substitute (dummy_constant cst)

let (inConstant : constant_obj -> obj) =
  declare_object { (default_object "CONSTANT") with
    cache_function = cache_constant;
    load_function = load_constant;
    open_function = open_constant;
    classify_function = classify_constant;
    subst_function = ident_subst_function;
    discharge_function = discharge_constant }

let declare_scheme = ref (fun _ _ -> assert false)
let set_declare_scheme f = declare_scheme := f

let update_tables c =
  declare_constant_implicits c;
  Notation.declare_ref_arguments_scope Evd.empty (ConstRef c)

let register_side_effect (c, role) =
  let o = inConstant {
    cst_decl = None;
    cst_kind = IsProof Theorem;
    cst_locl = false;
  } in
  let id = Label.to_id (Constant.label c) in
  ignore(add_leaf id o);
  update_tables c;
  match role with
  | Subproof -> ()
  | Schema (ind, kind) -> !declare_scheme kind [|ind,c|]

let declare_constant_common id cst =
  let o = inConstant cst in
  let _, kn as oname = add_leaf id o in
  pull_to_head oname;
  let c = Global.constant_of_delta_kn kn in
  update_tables c;
  c

let default_univ_entry = Monomorphic_entry Univ.ContextSet.empty
let definition_entry ?fix_exn ?(opaque=false) ?(inline=false) ?types
    ?(univs=default_univ_entry) ?(eff=Safe_typing.empty_private_constants) body =
  { const_entry_body = Future.from_val ?fix_exn ((body,Univ.ContextSet.empty), eff);
    const_entry_secctx = None;
    const_entry_type = types;
    const_entry_universes = univs;
    const_entry_opaque = opaque;
    const_entry_feedback = None;
    const_entry_inline_code = inline}

let declare_constant ?(internal = UserIndividualRequest) ?(local = false) id ?(export_seff=false) (cd, kind) =
  let is_poly de = match de.const_entry_universes with
  | Monomorphic_entry _ -> false
  | Polymorphic_entry _ -> true
  in
  let in_section = Lib.sections_are_opened () in
  let export, decl = (* We deal with side effects *)
    match cd with
    | DefinitionEntry de when
        export_seff ||
        not de.const_entry_opaque ||
        is_poly de ->
      (* This globally defines the side-effects in the environment. We mark
         exported constants as being side-effect not to redeclare them at
         caching time. *)
      let de, export = Global.export_private_constants ~in_section de in
      export, ConstantEntry (PureEntry, DefinitionEntry de)
    | _ -> [], ConstantEntry (EffectEntry, cd)
  in
  let () = List.iter register_side_effect export in
  let cst = {
    cst_decl = Some decl;
    cst_kind = kind;
    cst_locl = local;
  } in
  declare_constant_common id cst

let declare_definition ?(internal=UserIndividualRequest)
  ?(opaque=false) ?(kind=Decl_kinds.Definition) ?(local = false)
  id ?types (body,univs) =
  let cb =
    definition_entry ?types ~univs ~opaque body
  in
    declare_constant ~internal ~local id
      (Entries.DefinitionEntry cb, Decl_kinds.IsDefinition kind)

(** Declaration of section variables and local definitions *)
type section_variable_entry =
  | SectionLocalDef of Safe_typing.private_constants definition_entry
  | SectionLocalAssum of types Univ.in_universe_context_set * polymorphic * bool (** Implicit status *)

type variable_declaration = DirPath.t * section_variable_entry * logical_kind

let cache_variable ((sp,_),o) =
  match o with
  | Inl ctx -> Global.push_context_set false ctx
  | Inr (id,(p,d,mk)) ->
  (* Constr raisonne sur les noms courts *)
  if variable_exists id then
    alreadydeclared (Id.print id ++ str " already exists");

  let impl,opaq,poly,ctx = match d with (* Fails if not well-typed *)
    | SectionLocalAssum ((ty,ctx),poly,impl) ->
      let () = Global.push_named_assum ((id,ty,poly),ctx) in
      let impl = if impl then Implicit else Explicit in
        impl, true, poly, ctx
    | SectionLocalDef (de) ->
      let (de, eff) = Global.export_private_constants ~in_section:true de in
      let () = List.iter register_side_effect eff in
      (* The body should already have been forced upstream because it is a
         section-local definition, but it's not enforced by typing *)
      let (body, uctx), () = Future.force de.const_entry_body in
      let poly, univs = match de.const_entry_universes with
      | Monomorphic_entry uctx -> false, uctx
      | Polymorphic_entry (_, uctx) -> true, Univ.ContextSet.of_context uctx
      in
      let univs = Univ.ContextSet.union uctx univs in
      (* We must declare the universe constraints before type-checking the
         term. *)
      let () = Global.push_context_set (not poly) univs in
      let se = {
        secdef_body = body;
        secdef_secctx = de.const_entry_secctx;
        secdef_feedback = de.const_entry_feedback;
        secdef_type = de.const_entry_type;
      } in
      let () = Global.push_named_def (id, se) in
      Explicit, de.const_entry_opaque,
      poly, univs in
  Nametab.push (Nametab.Until 1) (restrict_path 0 sp) (VarRef id);
  add_section_variable id impl poly ctx;
  add_variable_data id (p,opaq,ctx,poly,mk)

let discharge_variable (_,o) = match o with
  | Inr (id,_) ->
    if variable_polymorphic id then None
    else Some (Inl (variable_context id))
  | Inl _ -> Some o

type variable_obj =
    (Univ.ContextSet.t, Id.t * variable_declaration) union

let inVariable : variable_obj -> obj =
  declare_object { (default_object "VARIABLE") with
    cache_function = cache_variable;
    discharge_function = discharge_variable;
    classify_function = (fun _ -> Dispose) }

(* for initial declaration *)
let declare_variable id obj =
  let oname = add_leaf id (inVariable (Inr (id,obj))) in
  declare_var_implicits id;
  Notation.declare_ref_arguments_scope Evd.empty (VarRef id);
  oname

(** Declaration of inductive blocks *)
let declare_inductive_argument_scopes kn mie =
  List.iteri (fun i {mind_entry_consnames=lc} ->
    Notation.declare_ref_arguments_scope Evd.empty (IndRef (kn,i));
    for j=1 to List.length lc do
      Notation.declare_ref_arguments_scope Evd.empty (ConstructRef ((kn,i),j));
    done) mie.mind_entry_inds

let inductive_names sp kn mie =
  let (dp,_) = repr_path sp in
  let kn = Global.mind_of_delta_kn kn in
  let names, _ =
    List.fold_left
      (fun (names, n) ind ->
	 let ind_p = (kn,n) in
	 let names, _ =
	   List.fold_left
	     (fun (names, p) l ->
		let sp =
		  Libnames.make_path dp l
		in
		  ((sp, ConstructRef (ind_p,p)) :: names, p+1))
	     (names, 1) ind.mind_entry_consnames in
	 let sp = Libnames.make_path dp ind.mind_entry_typename
	 in
	   ((sp, IndRef ind_p) :: names, n+1))
      ([], 0) mie.mind_entry_inds
  in names

let load_inductive i ((sp,kn),mie) =
  let names = inductive_names sp kn mie in
  List.iter (fun (sp, ref) -> Nametab.push (Nametab.Until i) sp ref ) names

let open_inductive i ((sp,kn),mie) =
  let names = inductive_names sp kn mie in
  List.iter (fun (sp, ref) -> Nametab.push (Nametab.Exactly i) sp ref) names

let cache_inductive ((sp,kn),mie) =
  let names = inductive_names sp kn mie in
  List.iter check_exists (List.map fst names);
  let id = basename sp in
  let kn' = Global.add_mind id mie in
  assert (MutInd.equal kn' (MutInd.make1 kn));
  let mind = Global.lookup_mind kn' in
  add_section_kn (Declareops.inductive_is_polymorphic mind) kn' mind.mind_hyps;
  List.iter (fun (sp, ref) -> Nametab.push (Nametab.Until 1) sp ref) names

let discharge_inductive ((sp,kn),mie) =
  let mind = Global.mind_of_delta_kn kn in
  let mie = Global.lookup_mind mind in
  let repl = replacement_context () in
  let info = section_segment_of_mutual_inductive mind in
  Some (Discharge.process_inductive info repl mie)

let dummy_one_inductive_entry mie = {
  mind_entry_typename = mie.mind_entry_typename;
  mind_entry_arity = mkProp;
  mind_entry_template = false;
  mind_entry_consnames = mie.mind_entry_consnames;
  mind_entry_lc = []
}

(* Hack to reduce the size of .vo: we keep only what load/open needs *)
let dummy_inductive_entry m = {
  mind_entry_params = [];
  mind_entry_record = None;
  mind_entry_finite = Declarations.BiFinite;
  mind_entry_inds = List.map dummy_one_inductive_entry m.mind_entry_inds;
  mind_entry_universes = default_univ_entry;
  mind_entry_variance = None;
  mind_entry_private = None;
}

(* reinfer subtyping constraints for inductive after section is dischared. *)
let rebuild_inductive mind_ent =
  let env = Global.env () in
  InferCumulativity.infer_inductive env mind_ent

let inInductive : mutual_inductive_entry -> obj =
  declare_object {(default_object "INDUCTIVE") with
    cache_function = cache_inductive;
    load_function = load_inductive;
    open_function = open_inductive;
    classify_function = (fun a -> Substitute (dummy_inductive_entry a));
    subst_function = ident_subst_function;
    discharge_function = discharge_inductive;
    rebuild_function = rebuild_inductive }

let declare_one_projection univs (mind,_ as ind) ~proj_npars proj_arg label (term,types) =
  let id = Label.to_id label in
  let univs, u = match univs with
    | Monomorphic_entry _ ->
      (* Global constraints already defined through the inductive *)
      default_univ_entry, Univ.Instance.empty
    | Polymorphic_entry (nas, ctx) ->
      Polymorphic_entry (nas, ctx), Univ.UContext.instance ctx
  in
  let term = Vars.subst_instance_constr u term in
  let types = Vars.subst_instance_constr u types in
  let entry = definition_entry ~types ~univs term in
  let cst = declare_constant id (DefinitionEntry entry, IsDefinition StructureComponent) in
  let p = Projection.Repr.make ind ~proj_npars ~proj_arg label in
  Recordops.declare_primitive_projection p cst


let declare_projections univs mind =
  let env = Global.env () in
  let mib = Environ.lookup_mind mind env in
  match mib.mind_record with
  | PrimRecord info ->
    let iter_ind i (_, labs, _, _) =
      let ind = (mind, i) in
      let projs = Inductiveops.compute_projections env ind in
      Array.iter2_i (declare_one_projection univs ind ~proj_npars:mib.mind_nparams) labs projs
    in
    let () = Array.iteri iter_ind info in
    true
  | FakeRecord -> false
  | NotRecord -> false

(* for initial declaration *)
let declare_mind mie =
  let id = match mie.mind_entry_inds with
    | ind::_ -> ind.mind_entry_typename
    | [] -> anomaly (Pp.str "cannot declare an empty list of inductives.") in
  let (sp,kn as oname) = add_leaf id (inInductive mie) in
  let mind = Global.mind_of_delta_kn kn in
  let isprim = declare_projections mie.mind_entry_universes mind in
  declare_mib_implicits mind;
  declare_inductive_argument_scopes mind mie;
  oname, isprim

(* Declaration messages *)

let pr_rank i = pr_nth (i+1)

let fixpoint_message indexes l =
  Flags.if_verbose Feedback.msg_info (match l with
  | [] -> anomaly (Pp.str "no recursive definition.")
  | [id] -> Id.print id ++ str " is recursively defined" ++
      (match indexes with
	 | Some [|i|] -> str " (decreasing on "++pr_rank i++str " argument)"
	 | _ -> mt ())
  | l -> hov 0 (prlist_with_sep pr_comma Id.print l ++
		  spc () ++ str "are recursively defined" ++
		  match indexes with
		    | Some a -> spc () ++ str "(decreasing respectively on " ++
			prvect_with_sep pr_comma pr_rank a ++
			str " arguments)"
		    | None -> mt ()))

let cofixpoint_message l =
  Flags.if_verbose Feedback.msg_info (match l with
  | [] -> anomaly (Pp.str "No corecursive definition.")
  | [id] -> Id.print id ++ str " is corecursively defined"
  | l -> hov 0 (prlist_with_sep pr_comma Id.print l ++
                    spc () ++ str "are corecursively defined"))

let recursive_message isfix i l =
  (if isfix then fixpoint_message i else cofixpoint_message) l

let definition_message id =
  Flags.if_verbose Feedback.msg_info (Id.print id ++ str " is defined")

let assumption_message id =
  (* Changing "assumed" to "declared", "assuming" referring more to
  the type of the object than to the name of the object (see
  discussion on coqdev: "Chapter 4 of the Reference Manual", 8/10/2015) *)
  Flags.if_verbose Feedback.msg_info (Id.print id ++ str " is declared")

(** Monomorphic universes need to survive sections. *)

let input_universe_context : Univ.ContextSet.t -> Libobject.obj =
  declare_object @@ local_object "Monomorphic section universes"
    ~cache:(fun (na, uctx) -> Global.push_context_set false uctx)
    ~discharge:(fun (_, x) -> Some x)

let declare_universe_context poly ctx =
  if poly then
    (Global.push_context_set true ctx; Lib.add_section_context ctx)
  else
    Lib.add_anonymous_leaf (input_universe_context ctx)

(** Global universes are not substitutive objects but global objects
   bound at the *library* or *module* level. The polymorphic flag is
   used to distinguish universes declared in polymorphic sections, which
   are discharged and do not remain in scope. *)

type universe_source =
  | BoundUniv (* polymorphic universe, bound in a function (this will go away someday) *)
  | QualifiedUniv of Id.t (* global universe introduced by some global value *)
  | UnqualifiedUniv (* other global universe *)

type universe_name_decl = universe_source * (Id.t * Univ.Level.UGlobal.t) list

let check_exists sp =
  if Nametab.exists_universe sp then
    alreadydeclared (str "Universe " ++ Id.print (basename sp) ++ str " already exists")
  else ()

let qualify_univ i dp src id =
  match src with
  | BoundUniv | UnqualifiedUniv ->
    i,  Libnames.make_path dp id
  | QualifiedUniv l ->
    let dp = DirPath.repr dp in
    Nametab.map_visibility succ i, Libnames.make_path (DirPath.make (l::dp)) id

let do_univ_name ~check i dp src (id,univ) =
  let i, sp = qualify_univ i dp src id in
  if check then check_exists sp;
  Nametab.push_universe i sp univ

let cache_univ_names ((sp, _), (src, univs)) =
  let depth = sections_depth () in
  let dp = pop_dirpath_n depth (dirpath sp) in
  List.iter (do_univ_name ~check:true (Nametab.Until 1) dp src) univs

let load_univ_names i ((sp, _), (src, univs)) =
  List.iter (do_univ_name ~check:false (Nametab.Until i) (dirpath sp) src) univs

let open_univ_names i ((sp, _), (src, univs)) =
  List.iter (do_univ_name ~check:false (Nametab.Exactly i) (dirpath sp) src) univs

let discharge_univ_names = function
  | _, (BoundUniv, _) -> None
  | _, ((QualifiedUniv _ | UnqualifiedUniv), _ as x) -> Some x

let input_univ_names : universe_name_decl -> Libobject.obj =
  declare_object
    { (default_object "Global universe name state") with
      cache_function = cache_univ_names;
      load_function = load_univ_names;
      open_function = open_univ_names;
      discharge_function = discharge_univ_names;
      subst_function = (fun (subst, a) -> (* Actually the name is generated once and for all. *) a);
      classify_function = (fun a -> Substitute a) }

let declare_univ_binders gr pl =
  if Global.is_polymorphic gr then
    ()
  else
    let l = match gr with
      | ConstRef c -> Label.to_id @@ Constant.label c
      | IndRef (c, _) -> Label.to_id @@ MutInd.label c
      | VarRef id -> anomaly ~label:"declare_univ_binders" Pp.(str "declare_univ_binders on variable " ++ Id.print id ++ str".")
      | ConstructRef _ ->
        anomaly ~label:"declare_univ_binders"
          Pp.(str "declare_univ_binders on an constructor reference")
    in
    let univs = Id.Map.fold (fun id univ univs ->
        match Univ.Level.name univ with
        | None -> assert false (* having Prop/Set/Var as binders is nonsense *)
        | Some univ -> (id,univ)::univs) pl []
    in
    Lib.add_anonymous_leaf (input_univ_names (QualifiedUniv l, univs))

let do_universe poly l =
  let in_section = Lib.sections_are_opened () in
  let () =
    if poly && not in_section then
      user_err ~hdr:"Constraint"
                   (str"Cannot declare polymorphic universes outside sections")
  in
  let l = List.map (fun {CAst.v=id} -> (id, UnivGen.new_univ_global ())) l in
  let ctx = List.fold_left (fun ctx (_,qid) -> Univ.LSet.add (Univ.Level.make qid) ctx)
      Univ.LSet.empty l, Univ.Constraint.empty
  in
  let () = declare_universe_context poly ctx in
  let src = if poly then BoundUniv else UnqualifiedUniv in
  Lib.add_anonymous_leaf (input_univ_names (src, l))

let do_constraint poly l =
  let open Univ in
  let u_of_id x =
    let level = Pretyping.interp_known_glob_level (Evd.from_env (Global.env ())) x in
    Lib.is_polymorphic_univ level, level
  in
  let in_section = Lib.sections_are_opened () in
  let () =
    if poly && not in_section then
      user_err ~hdr:"Constraint"
                    (str"Cannot declare polymorphic constraints outside sections")
  in
  let check_poly p p' =
    if poly then ()
    else if p || p' then
      user_err ~hdr:"Constraint"
                    (str "Cannot declare a global constraint on " ++
                    str "a polymorphic universe, use "
                    ++ str "Polymorphic Constraint instead")
  in
  let constraints = List.fold_left (fun acc (l, d, r) ->
     let p, lu = u_of_id l and p', ru = u_of_id r in
     check_poly p p';
     Constraint.add (lu, d, ru) acc)
    Constraint.empty l
  in
  let uctx = ContextSet.add_constraints constraints ContextSet.empty in
  declare_universe_context poly uctx
