(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Core_kernel
open Typing_defs

module Reason = Typing_reason

(*****************************************************************************)
(* Builds a substitution out of a list of type parameters and a list of types.
 *
 * Typical use-case:
 *   class Y<T> { ... }
 *   class X extends Y<int>
 *
 * To build the type of X, we need to replace all the occurrences of T in Y by
 * int. The function make_subst, builds the substitution (the map associating
 * types to a type parameter name), in this case, it would build the map(T =>
 * int).
 *)
(*****************************************************************************)

let make tparams tyl =
  (* We tolerate missing types in silent_mode. When that happens, we bind
   * all the parameters we can, and bind the remaining ones to "Tany".
   *)
  let make_subst_tparam (subst, tyl) (_, (_, tparam_name), _, _) =
    let ty, tyl =
      match tyl with
      | [] -> (Reason.Rnone, Tany), []
      | ty :: rl -> ty, rl
    in
    SMap.add tparam_name ty subst, tyl
  in
  let subst, _ = List.fold tparams ~init:(SMap.empty, tyl) ~f:make_subst_tparam in
  subst
