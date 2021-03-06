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

module Make(Name: S.NAME) = struct

type name = Name.t with sexp

(* Sparse allocation should be fast. Expanding memory should be fast, for a bunch of volumes. *)

type area = (name * (int64 * int64)) with sexp 
type t = area list with sexp

let to_string t = Sexplib.Sexp.to_string_hum (sexp_of_t t)

let (++) f g x = f (g x)
let ($) f a = f a
let uncurry f (a,b) = f a b
let on op f x y = op (f x) (f y)

let create name size = [(name,(0L,size))]
let empty = []

let get_name (name,(_,_)) = name
let get_start (_,(start,_)) = start
let get_size (_,(_,size)) = size
let unpack_area (pv_name, (start,size)) = (pv_name, (start,size))

let get_end a = Int64.add (get_start a) (get_size a)

let make_area pv_name start size = (pv_name, (start,size))
let make_area_by_end name start endAr = make_area name start (Int64.sub endAr start)

(* Define operations on areas, and then use those to build the
   allocation algorithms.  That should make it easier to test, and the
   algorithms are easier to read without arithmetic in them.
*)

let intersect : area -> area -> area list = 
    fun a a2 ->
	let (name, (start, size)) = unpack_area a in
	let (name2, (start2, size2)) = unpack_area a2 in
	let enda = get_end a in
	let enda2 = get_end a2 in
	let startI = max start start2 in
	let endI = min enda enda2 in
	let sizeI = max Int64.zero (Int64.sub endI startI) in
	if name = name2 
	then make_area name (max start start2) (max Int64.zero sizeI) :: []
	else []

let combine : t -> t -> t = (* does not guarantee normalization *)
    fun t1 t2 ->
	t1 @ t2 

let union : area -> area -> t = (* does not guarantee normalization *)
    fun a a2 ->
	a::a2::[]
let minus : area -> area -> t = (* does not guarantee normalization *)
    fun a a2 ->
	let (name, (start, size)) = unpack_area a in
	let (name2, (start2, size2)) = unpack_area a2 in
	let enda = get_end a in
	let enda2 = get_end a2 in
        if name = name2
	then List.filter ((<) Int64.zero ++ get_size) ++ List.fold_left combine [] ++ List.map (intersect a ++ uncurry (make_area_by_end name2)) $ ((start, start2) :: (enda2, enda)::[])
	else a :: []

let normalize areas =
    (* Merge adjacent extents by folding over them in order *)
    let normalise pairs =
      let pairs =
        pairs
        |> List.filter (fun (_, len) -> len <> 0L)
        |> List.sort (fun a b -> compare (fst a) (fst b)) in
      match pairs with
      | [] -> []
      | p :: ps ->
        let last, pairs =
          List.fold_left (fun ((merge_start, merge_size), acc) (next_start, next_size) ->
            let merge_end = Int64.(add merge_start merge_size)
            and next_end  = Int64.(add next_start  next_size) in
            if next_start > merge_end
            then ((next_start, next_size), (merge_start, merge_size) :: acc)
            else ((merge_start, Int64.(sub (max merge_end next_end) merge_start)), acc)
          ) (p, []) ps in
        last :: pairs in

    let module M = Map.Make(Name) in
    (* This would probably be a better structure to store the data in, rather than
       a jumbled list *)
    let by_name =
      List.fold_left (fun acc (name, e) ->
        M.add name (if M.mem name acc then e :: M.find name acc else [e]) acc
      ) M.empty areas in

    let by_name = M.map normalise by_name in

    M.fold (fun name pairs acc -> List.map (fun p -> name, p) pairs @ acc) by_name []

let alloc_specified_area (free_list : t) (a : area) =
    if get_size a = 0L
    then free_list
    else
        let t = List.concat (List.map (fun x -> minus x a) free_list) in
        normalize t

let sub : t -> t -> t =
   List.fold_left alloc_specified_area

let safe_alloc (free_list : t) (newsize : int64) =
    (* switched from best-fit (smallest free area that's large enough)
       to worst-fit (largest area): This may reduce fragmentation, and
       makes the code slightly easier. *)
    let rec alloc_h newsize = function
	| (seg::rest) -> 
	    let remainder = Int64.sub newsize (get_size seg) in
	    if (remainder > Int64.zero) then
                (* We couldn't find one contiguous region to allocate. Call alloc again
		   with the remainder of the size and the new list of allocated areas *)
		match alloc_h remainder rest with
		    | Some (allocd,newt) -> Some (seg::allocd, newt)
		    | None -> None
	    else
                let (name, (start, _)) = unpack_area seg in
                let area = make_area name start newsize in
                Some ([area], try (alloc_specified_area (seg::rest) area) with (Match_failure x) -> (print_endline "alloc_specified_area"; raise (Match_failure x)))
	| [] -> None in
    alloc_h newsize
    ++ List.rev ++ List.sort (on compare get_size) $ free_list

let size t = List.fold_left Int64.add 0L (List.map get_size t)

let find (free_list : t) (newsize : int64) =
    match safe_alloc free_list newsize
    with  Some (x, _) -> `Ok x
	| None ->
          `Error (`OnlyThisMuchFree (newsize, size free_list))

(* Probably de-allocation won't be used much. *)
let merge to_free free_list = normalize (combine to_free free_list)

let compare: t -> t -> int = compare
end

module StringAllocator = Make(struct
  type t = string with sexp
  let compare (a: t) (b: t) = compare a b
  let to_string x = x
end)
include StringAllocator
