(*
 * Copyright (C) 2009-2015 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Sexplib.Std

module Op = struct 
  type lvrename_t = {
    lvmv_new_name : string;
  }

  and lvreduce_t = {
    lvrd_new_extent_count : int64;
  }

  and lvexpand_t = {
    lvex_segments : Lv.Segment.t list;
  } with sexp

  (** First string corresponds to the name of the LV. *)
  type t =
    | LvCreate of Lv.t
    | LvReduce of Uuid.t * lvreduce_t
    | LvExpand of Uuid.t * lvexpand_t
    | LvRename of Uuid.t * lvrename_t
    | LvRemove of Uuid.t
    | LvAddTag of Uuid.t * Name.Tag.t
    | LvRemoveTag of Uuid.t * Name.Tag.t
    | LvSetStatus of Uuid.t * (Lv.Status.t list)
    | LvTransfer of Uuid.t * Uuid.t * Lv.Segment.t list
  with sexp

  let of_cstruct x =
    try
      Some (Cstruct.to_string x |> Sexplib.Sexp.of_string |> t_of_sexp)
    with _ -> 
      None

  let to_cstruct t =
    let s = sexp_of_t t |> Sexplib.Sexp.to_string in
    let c = Cstruct.create (String.length s) in
    Cstruct.blit_from_string s 0 c 0 (Cstruct.len c);
    c
end
