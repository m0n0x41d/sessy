open Sessy_domain

let read_file = Fs.read_file
let list_dir = Fs.list_dir
let file_exists = Fs.file_exists
let expand_home = Fs.expand_home
let detect_git_root = Fs.detect_git_root
let spawn = Process.spawn
let exec_replace = Process.exec_replace
let print_cmd = Process.print_cmd

let load_config () =
  Config_loader.load_config () |> fst

let load_config_from_paths = Config_loader.load_config_from_paths

let warning_for_source source_path message =
  Printf.sprintf "%s: %s" source_path message

let load_source source =
  let source_path = source.history_path |> expand_home in

  if not (file_exists source_path) then ([], [])
  else
    match read_file source_path with
    | Error (`Io_error message) ->
        ([], [ warning_for_source source_path message ])
    | Ok raw ->
        let module Adapter =
          (val Sessy_adapter.adapter_for_tool source.tool
              : Sessy_adapter.SOURCE)
        in

        Adapter.parse_history raw
        |> function
        | Ok sessions -> (sessions, [])
        | Error error ->
            let message =
              match error with
              | Invalid_json value -> value
              | Missing_field value -> "missing field: " ^ value
              | Invalid_format value -> value
            in

            ([], [ warning_for_source source_path message ])

let load_sessions config =
  config.sources
  |> List.fold_left
       (fun (all_sessions, warnings) source ->
         let sessions, source_warnings = load_source source in

         (all_sessions @ sessions, warnings @ source_warnings))
       ([], [])

let print_warnings warnings =
  warnings |> List.iter prerr_endline

let print_output text =
  if String.equal text "" then ()
  else print_endline text

let execute_cmd ~now = function
  | Sessy_ui.Print_sessions (sessions, output_format) ->
      sessions
      |> Sessy_ui.format_sessions ~now output_format
      |> print_output;
      0
  | Sessy_ui.Print_error message ->
      prerr_endline message;
      1

let execute_cmds ~now commands =
  commands
  |> List.map (execute_cmd ~now)
  |> List.fold_left Int.max 0

let run_once () =
  let config, config_warnings = Config_loader.load_config () in
  let sessions, session_warnings = load_sessions config in
  let index = sessions |> Sessy_index.build in
  let cwd = Sys.getcwd () in
  let _repo_root = detect_git_root cwd in
  let warnings = config_warnings @ session_warnings in

  print_warnings warnings;

  Sys.argv
  |> Array.to_list
  |> List.tl
  |> Sessy_ui.parse_cli
  |> function
  | Error message ->
      prerr_endline message;
      1
  | Ok action ->
      Sessy_ui.dispatch action index config ~cwd
      |> execute_cmds ~now:(Unix.gettimeofday ())

let run () =
  let exit_status = Eio_main.run (fun _env -> run_once ()) in

  exit exit_status
