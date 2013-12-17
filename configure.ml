let config_mk = "config.mk"

let find_ocamlfind verbose name =
  let found =
    try
      let (_: string) = Findlib.package_property [] name "requires" in
      true
    with
    | Not_found ->
      (* property within the package could not be found *)
      true
    | Findlib.No_such_package(_,_ ) ->
      false in
  if verbose then Printf.fprintf stderr "querying for ocamlfind package %s: %s" name (if found then "ok" else "missing");
  found

(* Configure script *)
open Cmdliner

let bindir =
  let doc = "Set the directory for installing binaries" in
  Arg.(value & opt string "/usr/bin" & info ["bindir"] ~docv:"BINDIR" ~doc)

let info =
  let doc = "Configures a package" in
  Term.info "configure" ~version:"0.1" ~doc 

let output_file filename lines =
  let oc = open_out filename in
  let lines = List.map (fun line -> line ^ "\n") lines in
  List.iter (output_string oc) lines;
  close_out oc

let configure bindir =

  Printf.printf "Configuring with:\n\tbindir=%s\n" bindir;

  let camldm = find_ocamlfind false "camldm" in
  let kaputt = find_ocamlfind false "kaputt" in
  let lines = 
    [ "# Warning - this file is autogenerated by the configure script";
      "# Do not edit";
      Printf.sprintf "BINDIR=%s" bindir;
      Printf.sprintf "CONFIGUREFLAGS=--%sable-mapper --%sable-tests"
        (if camldm then "en" else "dis")
        (if kaputt then "en" else "dis");
    ] in
  output_file config_mk lines

let configure_t = Term.(pure configure $ bindir )

let () = 
  match 
    Term.eval (configure_t, info) 
  with
  | `Error _ -> exit 1 
  | _ -> exit 0
