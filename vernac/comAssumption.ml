(************************************************************************)
(*         *   The Coq Proof Assistant / The Coq Development Team       *)
(*  v      *   INRIA, CNRS and contributors - Copyright 1999-2018       *)
(* <O___,, *       (see CREDITS file for the list of authors)           *)
(*   \VV/  **************************************************************)
(*    //   *    This file is distributed under the terms of the         *)
(*         *     GNU Lesser General Public License Version 2.1          *)
(*         *     (see LICENSE file for the text of the license)         *)
(************************************************************************)

open CErrors
open Util
open Vars
open Declare
open Names
open Globnames
open Constrexpr_ops
open Constrintern
open Impargs
open Decl_kinds
open Pretyping
open Entries

(* 2| Variable/Hypothesis/Parameter/Axiom declarations *)

let axiom_into_instance = ref false

let () =
  let open Goptions in
  declare_bool_option
    { optdepr = true;
      optname = "automatically declare axioms whose type is a typeclass as instances";
      optkey = ["Typeclasses";"Axioms";"Are";"Instances"];
      optread = (fun _ -> !axiom_into_instance);
      optwrite = (:=) axiom_into_instance; }

let should_axiom_into_instance = function
  | Discharge ->
    (* The typeclass behaviour of Variable and Context doesn't depend
       on section status *)
    true
  | Global | Local -> !axiom_into_instance

let declare_assumption is_coe (local,p,kind) (c,ctx) pl imps impl nl {CAst.v=ident} =
match local with
| Discharge when Lib.sections_are_opened () ->
  let ctx = match ctx with
    | Monomorphic_entry ctx -> ctx
    | Polymorphic_entry (_, ctx) -> Univ.ContextSet.of_context ctx
  in
  let decl = (Lib.cwd(), SectionLocalAssum ((c,ctx),p,impl), IsAssumption kind) in
  let _ = declare_variable ident decl in
  let () = assumption_message ident in
  let () =
    if not !Flags.quiet && Proof_global.there_are_pending_proofs () then
    Feedback.msg_info Pp.(str"Variable" ++ spc () ++ Id.print ident ++
    strbrk " is not visible from current goals")
  in
  let r = VarRef ident in
  let () = maybe_declare_manual_implicits true r imps in
  let () = Typeclasses.declare_instance None true r in
  let () = if is_coe then Class.try_add_new_coercion r ~local:true false in
  (r,Univ.Instance.empty,true)

| Global | Local | Discharge ->
  let do_instance = should_axiom_into_instance local in
  let local = DeclareDef.get_locality ident ~kind:"axiom" local in
  let inl = let open Declaremods in match nl with
    | NoInline -> None
    | DefaultInline -> Some (Flags.get_inline_level())
    | InlineAt i -> Some i
  in
  let decl = (ParameterEntry (None,(c,ctx),inl), IsAssumption kind) in
  let kn = declare_constant ident ~local decl in
  let gr = ConstRef kn in
  let () = maybe_declare_manual_implicits false gr imps in
  let () = Declare.declare_univ_binders gr pl in
  let () = assumption_message ident in
  let () = if do_instance then Typeclasses.declare_instance None false gr in
  let () = if is_coe then Class.try_add_new_coercion gr ~local p in
  let inst = match ctx with
    | Polymorphic_entry (_, ctx) -> Univ.UContext.instance ctx
    | Monomorphic_entry _ -> Univ.Instance.empty
  in
    (gr,inst,Lib.is_modtype_strict ())

let interp_assumption ~program_mode sigma env impls c =
  let sigma, (ty, impls) = interp_type_evars_impls ~program_mode env sigma ~impls c in
  sigma, (ty, impls)

(* When monomorphic the universe constraints are declared with the first declaration only. *)
let next_uctx =
  let empty_uctx = Monomorphic_entry Univ.ContextSet.empty in
  function
  | Polymorphic_entry _ as uctx -> uctx
  | Monomorphic_entry _ -> empty_uctx

let declare_assumptions idl is_coe k (c,uctx) pl imps nl =
  let refs, status, _ =
    List.fold_left (fun (refs,status,uctx) id ->
      let ref',u',status' =
        declare_assumption is_coe k (c,uctx) pl imps false nl id in
      (ref',u')::refs, status' && status, next_uctx uctx)
      ([],true,uctx) idl
  in
  List.rev refs, status


let maybe_error_many_udecls = function
  | ({CAst.loc;v=id}, Some _) ->
    user_err ?loc ~hdr:"many_universe_declarations"
      Pp.(str "When declaring multiple axioms in one command, " ++
          str "only the first is allowed a universe binder " ++
          str "(which will be shared by the whole block).")
  | (_, None) -> ()

let process_assumptions_udecls kind l =
  let udecl, first_id = match l with
    | (coe, ((id, udecl)::rest, c))::rest' ->
      List.iter maybe_error_many_udecls rest;
      List.iter (fun (coe, (idl, c)) -> List.iter maybe_error_many_udecls idl) rest';
      udecl, id
    | (_, ([], _))::_ | [] -> assert false
  in
  let () = match kind, udecl with
    | (Discharge, _, _), Some _ when Lib.sections_are_opened () ->
      let loc = first_id.CAst.loc in
      let msg = Pp.str "Section variables cannot be polymorphic." in
      user_err ?loc  msg
    | _ -> ()
  in
  udecl, List.map (fun (coe, (idl, c)) -> coe, (List.map fst idl, c)) l

let do_assumptions ~program_mode kind nl l =
  let open Context.Named.Declaration in
  let env = Global.env () in
  let udecl, l = process_assumptions_udecls kind l in
  let sigma, udecl = interp_univ_decl_opt env udecl in
  let l =
    if pi2 kind (* poly *) then
      (* Separate declarations so that A B : Type puts A and B in different levels. *)
      List.fold_right (fun (is_coe,(idl,c)) acc ->
        List.fold_right (fun id acc ->
          (is_coe, ([id], c)) :: acc) idl acc)
        l []
    else l
  in
  (* We intepret all declarations in the same evar_map, i.e. as a telescope. *)
  let (sigma,_,_),l = List.fold_left_map (fun (sigma,env,ienv) (is_coe,(idl,c)) ->
    let sigma,(t,imps) = interp_assumption ~program_mode sigma env ienv c in
    let env =
      EConstr.push_named_context (List.map (fun {CAst.v=id} -> LocalAssum (id,t)) idl) env in
    let ienv = List.fold_right (fun {CAst.v=id} ienv ->
      let impls = compute_internalization_data env sigma Variable t imps in
      Id.Map.add id impls ienv) idl ienv in
      ((sigma,env,ienv),((is_coe,idl),t,imps)))
    (sigma,env,empty_internalization_env) l
  in
  let sigma = solve_remaining_evars all_and_fail_flags env sigma in
  (* The universe constraints come from the whole telescope. *)
  let sigma = Evd.minimize_universes sigma in
  let nf_evar c = EConstr.to_constr sigma c in
  let uvars, l = List.fold_left_map (fun uvars (coe,t,imps) ->
      let t = nf_evar t in
      let uvars = Univ.LSet.union uvars (Vars.universes_of_constr t) in
      uvars, (coe,t,imps))
      Univ.LSet.empty l
  in
  let sigma = Evd.restrict_universe_context sigma uvars in
  let uctx = Evd.check_univ_decl ~poly:(pi2 kind) sigma udecl in
  let ubinders = Evd.universe_binders sigma in
  pi2 (List.fold_left (fun (subst,status,uctx) ((is_coe,idl),t,imps) ->
      let t = replace_vars subst t in
      let refs, status' = declare_assumptions idl is_coe kind (t,uctx) ubinders imps nl in
      let subst' = List.map2
          (fun {CAst.v=id} (c,u) -> (id, Constr.mkRef (c,u)))
          idl refs
      in
      subst'@subst, status' && status, next_uctx uctx)
    ([], true, uctx) l)

let do_primitive id prim typopt =
  if Lib.sections_are_opened () then
    CErrors.user_err Pp.(str "Declaring a primitive is not allowed in sections.");
  if Dumpglob.dump () then Dumpglob.dump_definition id false "ax";
  let env = Global.env () in
  let evd = Evd.from_env env in
  let evd, typopt = Option.fold_left_map
      (interp_type_evars_impls ~impls:empty_internalization_env env)
      evd typopt
  in
  let evd = Evd.minimize_universes evd in
  let uvars, impls, typopt = match typopt with
    | None -> Univ.LSet.empty, [], None
    | Some (ty,impls) ->
      EConstr.universes_of_constr evd ty, impls, Some (EConstr.to_constr evd ty)
  in
  let evd = Evd.restrict_universe_context evd uvars in
  let uctx = UState.check_mono_univ_decl (Evd.evar_universe_context evd) UState.default_univ_decl in
  let entry = { prim_entry_type = typopt;
                prim_entry_univs = uctx;
                prim_entry_content = prim;
              }
  in
  let _kn = declare_constant id.CAst.v (PrimitiveEntry entry,IsPrimitive) in
  Flags.if_verbose Feedback.msg_info Pp.(Id.print id.CAst.v ++ str " is declared")
