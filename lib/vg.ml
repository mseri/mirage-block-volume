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
open Absty
open Redo
open Logging
open Result

module Status = struct
  type t =
    | Read
    | Write
    | Resizeable
    | Clustered
  with sexp

  let to_string = function
    | Resizeable -> "RESIZEABLE"
    | Write -> "WRITE"
    | Read -> "READ"
    | Clustered -> "CLUSTERED"

  let of_string = function
    | "RESIZEABLE" -> return Resizeable
    | "WRITE" -> return Write
    | "READ" -> return Read
    | "CLUSTERED" -> return Clustered
    | x -> fail (Printf.sprintf "Bad VG status string: %s" x)
end

type metadata = {
  name : string;
  id : Uuid.t;
  seqno : int;
  status : Status.t list;
  extent_size : int64;
  max_lv : int;
  max_pv : int;
  pvs : Pv.t list; (* Device to pv map *)
  lvs : Lv.t list;
  free_space : Pv.Allocator.t;
  (* XXX: hook in the redo log *)
} with sexp
  
let marshal vg b =
  let b = ref b in
  let bprintf fmt = Printf.kprintf (fun s ->
    let len = String.length s in
    Cstruct.blit_from_string s 0 !b 0 len;
    b := Cstruct.shift !b len
  ) fmt in
  bprintf "%s {\nid = \"%s\"\nseqno = %d\n" vg.name (Uuid.to_string vg.id) vg.seqno;
  bprintf "status = [%s]\nextent_size = %Ld\nmax_lv = %d\nmax_pv = %d\n\n"
    (String.concat ", " (List.map (o quote Status.to_string) vg.status))
    vg.extent_size vg.max_lv vg.max_pv;
  bprintf "physical_volumes {\n";
  b := List.fold_left (fun b pv -> Pv.marshal pv b) !b vg.pvs;
  bprintf "}\n\n";

  bprintf "logical_volumes {\n";
  b := List.fold_left (fun b lv -> Lv.marshal lv b) !b vg.lvs;
  bprintf "}\n}\n";

  bprintf "# Generated by MLVM version 0.1: \n\n";
  bprintf "contents = \"Text Format Volume Group\"\n";
  bprintf "version = 1\n\n";
  bprintf "description = \"\"\n\n";
  bprintf "creation_host = \"%s\"\n" "<need uname!>";
  bprintf "creation_time = %Ld\n\n" (Int64.of_float (Unix.time ()));
  !b
    
(*************************************************************)
(* METADATA CHANGING OPERATIONS                              *)
(*************************************************************)

type op = Redo.Op.t

let do_op vg op : (metadata * op, string) Result.result =
  let open Redo.Op in
  let change_lv lv_name fn =
    let lv,others = List.partition (fun lv -> lv.Lv.name=lv_name) vg.lvs in
    match lv with
    | [lv] -> fn lv others
    | _ -> fail (Printf.sprintf "VG: unknown LV %s" lv_name) in
  match op with
  | LvCreate (name,l) ->
    let new_free_space = Pv.Allocator.sub vg.free_space l.lvc_segments in
    let segments = Lv.Segment.sort (Lv.Segment.linear 0L l.lvc_segments) in
    let lv = Lv.({ name; id = l.lvc_id; tags = []; status = [Status.Read; Status.Write; Status.Visible]; segments }) in
    return ({vg with lvs = lv::vg.lvs; free_space = new_free_space},op)
  | LvExpand (name,l) ->
    change_lv name (fun lv others ->
      (* Compute the new physical extents, remove from free space *)
      let extents = List.fold_left (fun acc x ->
        Pv.Allocator.merge acc (Lv.Segment.to_allocation x)
      ) [] l.lvex_segments in
      let free_space = Pv.Allocator.sub vg.free_space extents in
      (* This operation is idempotent so we assume that segments may be
         duplicated. We remove the duplicates here. *)
      let segments =
           Lv.Segment.sort (l.lvex_segments @ lv.Lv.segments)
        |> List.fold_left (fun (last_start, acc) segment ->
             (* Check if the segments are identical *)
             if segment.Lv.Segment.start_extent = last_start
             then last_start, acc
             else segment.Lv.Segment.start_extent, segment :: acc
           ) (-1L, [])
        |> snd
        |> List.rev in
      let lv = {lv with Lv.segments} in
      return ({vg with lvs = lv::others; free_space=free_space},op))
  | LvCrop (name, l) ->
    change_lv name (fun lv others ->
      let current = Lv.to_allocation lv in
      let to_free = List.fold_left Pv.Allocator.merge [] (List.map Lv.Segment.to_allocation l.lvc_segments) in
      let reduced = Pv.Allocator.sub current to_free in
      let free_space = Pv.Allocator.merge vg.free_space to_free in

      let segments = Lv.Segment.linear 0L reduced in
      return ({vg with lvs = lv::others; free_space},op))
  | LvReduce (name,l) ->
    change_lv name (fun lv others ->
      let allocation = Lv.to_allocation lv in
      Lv.reduce_size_to lv l.lvrd_new_extent_count >>= fun lv ->
      let new_allocation = Lv.to_allocation lv in
      let free_space = Pv.Allocator.sub (Pv.Allocator.merge vg.free_space allocation) new_allocation in
      return ({vg with lvs = lv::others; free_space},op))
  | LvRemove name ->
    change_lv name (fun lv others ->
      let allocation = Lv.to_allocation lv in
      return ({vg with lvs = others; free_space = Pv.Allocator.merge vg.free_space allocation },op))
  | LvRename (name,l) ->
    change_lv name (fun lv others ->
      return ({vg with lvs = {lv with Lv.name=l.lvmv_new_name}::others },op))
  | LvAddTag (name, tag) ->
    change_lv name (fun lv others ->
      let tags = lv.Lv.tags in
      let lv' = {lv with Lv.tags = if List.mem tag tags then tags else tag::tags} in
      return ({vg with lvs = lv'::others},op))
  | LvRemoveTag (name, tag) ->
    change_lv name (fun lv others ->
      let tags = lv.Lv.tags in
      let lv' = {lv with Lv.tags = List.filter (fun t -> t <> tag) tags} in
      return ({vg with lvs = lv'::others},op))

(* Convert from bytes to extents, rounding up *)
let bytes_to_extents bytes vg =
  let extents_in_sectors = vg.extent_size in
  let open Int64 in
  let extents_in_bytes = mul extents_in_sectors 512L in
  div (add bytes (sub extents_in_bytes 1L)) extents_in_bytes

let create vg name size = 
  if List.exists (fun lv -> lv.Lv.name = name) vg.lvs
  then `Error "Duplicate name detected"
  else match Pv.Allocator.find vg.free_space (bytes_to_extents size vg) with
  | `Ok lvc_segments ->
    let lvc_id = Uuid.create () in
    do_op vg Redo.Op.(LvCreate (name,{lvc_id; lvc_segments}))
  | `Error free ->
    `Error (Printf.sprintf "insufficient free space: requested %Ld, free %Ld" size free)

let rename vg old_name new_name =
  do_op vg Redo.Op.(LvRename (old_name,{lvmv_new_name=new_name}))

let resize vg name new_size =
  let new_size = bytes_to_extents new_size vg in
  let lv,others = List.partition (fun lv -> lv.Lv.name=name) vg.lvs in
  ( match lv with 
    | [lv] ->
	let current_size = Lv.size_in_extents lv in
        let to_allocate = Int64.sub new_size current_size in
	if to_allocate > 0L then match Pv.Allocator.find vg.free_space to_allocate with
        | `Ok extents ->
           let lvex_segments = Lv.Segment.linear current_size extents in
	   return Redo.Op.(LvExpand (name,{lvex_segments}))
        | `Error free ->
          `Error (Printf.sprintf "insufficient free space: requested %Ld, free %Ld" to_allocate free)
	else
	  return Redo.Op.(LvReduce (name,{lvrd_new_extent_count=new_size}))
    | _ -> fail (Printf.sprintf "Can't find LV %s" name) ) >>= fun op ->
  do_op vg op

let remove vg name =
  do_op vg Redo.Op.(LvRemove name)

let add_tag vg name tag =
  do_op vg Redo.Op.(LvAddTag (name, tag))

let remove_tag vg name tag =
  do_op vg Redo.Op.(LvRemoveTag (name, tag))

module Make(Block: S.BLOCK) = struct

module Pv_IO = Pv.Make(Block)
module Label_IO = Label.Make(Block)
module Metadata_IO = Metadata.Make(Block)

open IO

type devices = (Pv.Name.t * Block.t) list

type vg = metadata * devices

let metadata_of = fst
let devices_of = snd

let id_to_devices devices =
  (* We need the uuid contained within the Pv_header to figure out
     the mapping between PV and real device. Note we don't use the
     device 'hint' within the metadata itself. *)
  IO.FromResult.all (Lwt_list.map_p (fun device ->
    Label_IO.read device
    >>= fun label ->
    return (label.Label.pv_header.Label.Pv_header.id, device)
  ) devices)

let write (vg, name_to_devices) =
  let devices = List.map snd name_to_devices in
  id_to_devices devices
  >>= fun id_to_devices ->

  let buf = Cstruct.create (Int64.to_int Constants.max_metadata_size) in
  let buf' = marshal vg buf in
  let md = Cstruct.sub buf 0 buf'.Cstruct.off in
  let open IO.FromResult in
  let rec write_pv pv acc = function
    | [] -> return (List.rev acc)
    | m :: ms ->
      if not(List.mem_assoc pv.Pv.id id_to_devices)
      then fail (Printf.sprintf "Unable to find device corresponding to PV %s" (Uuid.to_string pv.Pv.id))
      else begin
        let open IO in
        Metadata_IO.write (List.assoc pv.Pv.id id_to_devices) m md >>= fun h ->
        write_pv pv (h :: acc) ms
      end in
  let rec write_vg acc = function
    | [] -> return (List.rev acc)
    | pv :: pvs ->
      if not(List.mem_assoc pv.Pv.id id_to_devices)
      then fail (Printf.sprintf "Unable to find device corresponding to PV %s" (Uuid.to_string pv.Pv.id))
      else begin
        let open IO in
        Label_IO.write (List.assoc pv.Pv.id id_to_devices) pv.Pv.label >>= fun () ->
        write_pv pv [] pv.Pv.headers >>= fun headers ->
        write_vg ({ pv with Pv.headers = headers } :: acc) pvs
      end in
  let open IO in
  write_vg [] vg.pvs >>= fun pvs ->
  let vg = { vg with pvs } in
  return (vg, name_to_devices)

let update (metadata, devices) ops =
  let open Result in
  let rec loop metadata = function
    | [] -> return metadata
    | x :: xs ->
      do_op metadata x
      >>= fun (metadata, _) ->
      loop metadata xs in
  let open IO.FromResult in
  loop metadata ops
  >>= fun metadata ->
  write (metadata, devices)

let format name ?(magic = `Lvm) devices =
  let open IO in
  let rec write_pv acc = function
    | [] -> return (List.rev acc)
    | (name, dev) :: pvs ->
      Pv_IO.format dev ~magic name >>= fun pv ->
      write_pv (pv :: acc) pvs in
  write_pv [] devices >>= fun pvs ->
  debug "PVs created";
  let free_space = List.flatten (List.map (fun pv -> Pv.Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in
  let vg = { name; id=Uuid.create (); seqno=1; status=[Status.Read; Status.Write];
    extent_size=Constants.extent_size_in_sectors; max_lv=0; max_pv=0; pvs;
    lvs=[]; free_space; } in
  write (vg, devices) >>= fun _ ->
  debug "VG created";
  return ()

let read devices =
  id_to_devices devices
  >>= fun id_to_devices ->

  (* Read metadata from any of the provided devices *)
  ( match devices with
    | [] -> return (`Error "Vg.read needs at least one device")
    | devices -> begin
      IO.FromResult.all (Lwt_list.map_s Pv_IO.read_metadata devices) >>= function
      | [] -> return (`Error "Failed to find metadata on any of the devices")
      | md :: _ ->
        let text = Cstruct.to_string md in
        let lexbuf = Lexing.from_string text in
        return (`Ok (Lvmconfigparser.start Lvmconfiglex.lvmtok lexbuf))
      end ) >>= fun config ->
  let open IO.FromResult in
  ( match config with
    | `Ok (AStruct c) -> `Ok c
    | _ -> `Error "VG metadata doesn't begin with a structure element" ) >>= fun config ->
  let vg = filter_structs config in
  ( match vg with
    | [ name, _ ] -> `Ok name
    | [] -> `Error "VG metadata contains no defined volume groups"
    | _ -> `Error "VG metadata contains multiple volume groups" ) >>= fun name ->
  expect_mapped_struct name vg >>= fun alist ->
  expect_mapped_string "id" alist >>= fun id ->
  Uuid.of_string id >>= fun id ->
  expect_mapped_int "seqno" alist >>= fun seqno ->
  let seqno = Int64.to_int seqno in
  map_expected_mapped_array "status" 
    (fun a -> let open Result in expect_string "status" a >>= fun x ->
              Status.of_string x) alist >>= fun status ->
  expect_mapped_int "extent_size" alist >>= fun extent_size ->
  expect_mapped_int "max_lv" alist >>= fun max_lv ->
  let max_lv = Int64.to_int max_lv in
  expect_mapped_int "max_pv" alist >>= fun max_pv ->
  let max_pv = Int64.to_int max_pv in
  expect_mapped_struct "physical_volumes" alist >>= fun pvs ->
  ( match expect_mapped_struct "logical_volumes" alist with
    | `Ok lvs -> `Ok lvs
    | `Error _ -> `Ok [] ) >>= fun lvs ->
  let open IO in
  all (Lwt_list.map_s (fun (a,_) ->
    let open IO.FromResult in
    expect_mapped_struct a pvs >>= fun x ->
    expect_mapped_string "id" x >>= fun id ->
    match Uuid.of_string id with
    | `Ok id ->
      if not(List.mem_assoc id id_to_devices)
      then fail (Printf.sprintf "Unable to find a device containing PV with id %s" (Uuid.to_string id))
      else Pv_IO.read (List.assoc id id_to_devices) a x
    | `Error x -> fail x
  ) pvs) >>= fun pvs ->
  all (Lwt_list.map_s (fun (a,_) ->
    let open IO.FromResult in
    expect_mapped_struct a lvs >>= fun x ->
    Lwt.return (Lv.of_metadata a x)
  ) lvs) >>= fun lvs ->

  (* Now we need to set up the free space structure in the PVs *)
  let free_space = List.flatten (List.map (fun pv -> Pv.Allocator.create pv.Pv.name pv.Pv.pe_count) pvs) in

  let free_space = List.fold_left (fun free_space lv -> 
    let lv_allocations = Lv.to_allocation lv in
    debug "Allocations for lv %s: %s" lv.Lv.name (Pv.Allocator.to_string lv_allocations);
    Pv.Allocator.sub free_space lv_allocations) free_space lvs in
  let vg = { name; id; seqno; status; extent_size; max_lv; max_pv; pvs; lvs;  free_space; } in
  (* Segments reference PVs by name, not uuid, so we need to build up
     the name to device mapping. *)
  let id_to_name = List.map (fun pv -> pv.Pv.id, pv.Pv.name) pvs in
  let name_to_devices =
    id_to_devices
  |> List.map (fun (id, device) ->
      if List.mem_assoc id id_to_name
      then Some (List.assoc id id_to_name, device)
      else None (* passed in devices list was a proper superset of pvs in metadata *)
     )
  |> List.fold_left (fun acc x -> match x with None -> acc | Some x -> x :: acc) [] in
  return (vg, name_to_devices)

module Volume = struct
  type id = {
    vg: vg;
    name: string;
  }
  type t = {
    id: id;
    devices: devices;
    name_to_pe_starts: (Pv.Name.t * int64) list;
    sector_size: int;
    extent_size: int64;
    lv: Lv.t;
    mutable disconnected: bool;
  }

  let id t = t.id

  type error = [
    | `Unknown of string
    | `Unimplemented
    | `Is_read_only
    | `Disconnected
  ]

  type info = {
    read_write: bool;
    sector_size: int;
    size_sectors: int64;
  }

  type 'a io = 'a Lwt.t

  type page_aligned_buffer = Cstruct.t

  open Lwt

  let connect id =
    let metadata = fst id.vg in
    let devices = snd id.vg in
    match try Some (List.find (fun x -> x.Lv.name = id.name) metadata.lvs) with Not_found -> None with
    | None -> return (`Error (`Unknown (Printf.sprintf "There is no volume named '%s'" id.name)))
    | Some lv ->
      (* We need the to add the pe_start later *)
      let name_to_pe_starts = List.map (fun (name, _) ->
        let pv = List.find (fun x -> x.Pv.name = name) metadata.pvs in
        name, pv.Pv.pe_start
      ) devices in
      (* We require all the devices to have identical sector sizes *)
      Lwt_list.map_p
        (fun (_, device) ->
          Block.get_info device
          >>= fun info ->
          return info.Block.sector_size
        ) devices
      >>= fun sizes ->
      let biggest = List.fold_left max min_int sizes in
      let smallest = List.fold_left min max_int sizes in
      if biggest <> smallest
      then return (`Error (`Unknown (Printf.sprintf "The underlying block devices have mixed sector sizes: %d <> %d" smallest biggest)))
      else
        return (`Ok {
          id; devices; sector_size = biggest; extent_size = metadata.extent_size;
          disconnected = false; lv; name_to_pe_starts;
        })

  let get_info t =
    let read_write = List.mem Lv.Status.Write t.lv.Lv.status in
    let segments = List.fold_left (fun acc s -> Int64.add acc s.Lv.Segment.extent_count) 0L t.lv.Lv.segments in
    let size_sectors = Int64.mul segments t.extent_size in
    return { read_write; sector_size = t.sector_size; size_sectors }

  let (>>|=) m f = m >>= function
  | `Error e -> return (`Error e)
  | `Ok x -> f x
  
  let io op t sector_start buffers =
    if t.disconnected
    then return (`Error `Disconnected)
    else begin
      let rec loop sector_start = function
      | [] -> return (`Ok ())
      | b :: bs ->
        let start_le = Int64.div sector_start t.extent_size in
        let start_offset = Int64.rem sector_start t.extent_size in
        match Lv.find_extent t.lv start_le with
        | Some { Lv.Segment.cls = Lv.Segment.Linear l; start_extent; extent_count } ->
          let start_pe = Int64.(add l.Lv.Linear.start_extent (sub start_le start_extent)) in
          let phys_offset = Int64.(add (mul start_pe t.extent_size) start_offset) in
          let will_read = min (Cstruct.len b / t.sector_size) (Int64.to_int t.extent_size) in
          if List.mem_assoc l.Lv.Linear.name t.devices then begin
            let device = List.assoc l.Lv.Linear.name t.devices in
            let pe_start = List.assoc l.Lv.Linear.name t.name_to_pe_starts in
            op device (Int64.add pe_start phys_offset) [ Cstruct.sub b 0 (will_read * t.sector_size) ]
            >>|= fun () ->
            let b = Cstruct.shift b (will_read * t.sector_size) in
            let bs = if Cstruct.len b > 0 then b :: bs else bs in
            let sector_start = Int64.(add sector_start (of_int will_read)) in
            loop sector_start bs
          end else return (`Error (`Unknown (Printf.sprintf "Unknown physical volume %s" (Pv.Name.to_string l.Lv.Linear.name))))
        | Some _ -> return (`Error (`Unknown "I only understand linear mapping"))
        | None -> return (`Error (`Unknown (Printf.sprintf "Logical extent %Ld has no segment" start_le))) in
      loop sector_start buffers
    end

  let read = io Block.read
  let write = io Block.write

  let disconnect t =
    t.disconnected <- true;
    return ()
end

end
(*
let set_dummy_mode base_dir mapper_name full_provision =
  Constants.dummy_mode := true;
  Constants.dummy_base := base_dir;
  Constants.mapper_name := mapper_name;
  Constants.full_provision := full_provision
*)
