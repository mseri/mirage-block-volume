(*
 * Copyright (C) 2009-2013 Citrix Systems Inc.
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
open Lvm_internal

type error = [
  | `Msg of string
]

type 'a result = ('a, error) Result.result

val open_error: 'a result -> ('a, [> error]) Result.result

module Status : sig
  type t = 
    | Allocatable

  include S.PRINT with type t := t

  val of_string: string -> t result
end

module Name : sig
  type t with sexp

  val to_string: t -> string

  val of_string: string -> t result
end

type t = {
  name : Name.t;                        (** unique name within a volume group *)
  id : Uuid.t;                          (** arbitrary unique id *)
  status : Status.t list;               (** status flags *)
  size_in_sectors : int64;              (** size of the device in 512 byte sectors *)
  pe_start : int64;                     (** sector number of the first physical extent *)
  pe_count : int64;                     (** total number of physical extents *)
  label : Label.t;
  headers : Metadata.Header.t list;     (** these describe the location(s) where VG metadata is stored *)
} with sexp
(** a Physical Volume (a disk), which is associated with a Volume Group *)

include S.MARSHAL with type t := t

module Make : functor(Block: S.BLOCK) -> sig
  val format: Block.t -> ?magic: Magic.t -> Name.t -> t result Lwt.t
  (** [format device ?kind name] initialises a physical volume on [device]
      with [name]. One metadata area will be created, 10 MiB in size,
      at a fixed location. Any existing metadata on this device will
      be destroyed. *)

  val wipe: Block.t -> unit result Lwt.t
  (** [wipe device] hides labels and metadata from [device] *)

  val unwipe: Block.t -> unit result Lwt.t
  (** [unwipe device] attempts to restore hidden labels and metadata on [device] *)

  val read_metadata: Block.t -> Cstruct.t result Lwt.t
  (** [read_metadata device]: locates the metadata area on [device] and
      returns the volume group metadata. *)

  val read: Block.t -> string -> (string * Absty.absty) list -> t result Lwt.t
  (** [read device name config] reads the information of physical volume [name]
      with configuration [config] read from the volume group metadata. *)
end

module Allocator: S.ALLOCATOR
  with type name = Name.t
