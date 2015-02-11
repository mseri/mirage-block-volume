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

open OUnit
open Lvm
open Vg
open Lwt

module Disk_mirage_unix = Disk_mirage.Make(Block)(Io_page)
module Vg_IO_mirage = Vg.Make(Disk_mirage_unix)
module Vg_IO_dummy = Vg.Make(Disk_dummy)

let (>>|=) m f = m >>= function
  | `Error e -> fail (Failure e)
  | `Ok x -> f x
let (>>*=) m f = match m with
  | `Error e -> fail (Failure e)
  | `Ok x -> f x

let with_dummy fn =
  let filename = "/tmp/vg" in
  let f = Unix.openfile filename [Unix.O_CREAT; Unix.O_RDWR] 0o644 in
  let s = Unix.lseek f (1024*1024*100 - 1) Unix.SEEK_SET in
  ignore(Unix.write f "\000" 0 1);
  Unix.close f;
  try 
    let result = fn filename in
    Unix.unlink filename;
    result
  with e ->
    Unix.unlink filename;
    raise e

let expect_failure f x =
  match f x with 
  | `Ok _ -> `Error "Expected failure"
  | `Error _ -> `Ok ()

let mirage_lv_name_clash () =
  let open Vg_IO_mirage in
  let size = Int64.(mul (mul 1024L 1024L) 4L) in
  with_dummy (fun filename ->
      let t = 
        Vg_IO_mirage.format "vg" [ filename, "pv" ] >>|= fun () ->
        Vg_IO_mirage.read [ filename ] >>|= fun vg ->
        Vg.create vg "name" size >>*= fun (vg,_) ->
        expect_failure (Vg.create vg "name") size >>*= 
        Lwt.return
      in
      Lwt_main.run t)

let vg_mirage_suite = "Vg" >::: [
    "LV name clash" >:: mirage_lv_name_clash;
  ]

let _ =
  let verbose = ref false in
  Arg.parse [
    "-verbose", Arg.Unit (fun _ -> verbose := true), "Run in verbose mode";
  ] (fun x -> Printf.fprintf stderr "Ignoring argument: %s" x)
    "VG test suite";

  List.iter (fun suite -> ignore (run_test_tt ~verbose:!verbose suite)) [
    vg_mirage_suite
  ]