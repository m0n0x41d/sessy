open Sessy_domain

type handlers = {
  copy_to_clipboard : string -> (string option, string) result;
  open_directory : string -> (string option, string) result;
  open_session_directory : Session_id.t -> (string option, string) result;
  resolve_launch :
    Session_id.t -> Sessy_ui.launch_mode -> (launch_cmd, string) result;
  resolve_preview : Session_id.t -> (Sessy_ui.preview, string) result;
  reload_snapshot : unit -> (Sessy_ui.reload_snapshot, string) result;
}

type outcome =
  | Continue of Sessy_ui.model
  | Finish of [ `Exit | `Launch of launch_cmd ]

let default_terminal = { Sessy_ui.width = 120; height = 24 }
let tty_in = Unix.descr_of_in_channel Stdlib.stdin

let with_alt_screen render =
  output_string Stdlib.stdout "\027[?1049h\027[?25l";
  flush Stdlib.stdout;

  Fun.protect
    ~finally:(fun () ->
      output_string Stdlib.stdout "\027[?25h\027[?1049l";
      flush Stdlib.stdout)
    render

let prepare_terminal fd =
  let original = Unix.tcgetattr fd in
  let raw =
    { original with c_icanon = false; c_echo = false; c_isig = false }
  in

  raw.c_ixon <- false;
  raw.c_ixoff <- false;
  raw.c_vmin <- 1;
  raw.c_vtime <- 0;

  Unix.tcsetattr fd Unix.TCSAFLUSH raw;

  original

let terminal_size () =
  let process = Unix.open_process_in "stty size 2>/dev/null" in
  let parsed =
    try
      let line = input_line process in
      let tokens =
        line |> String.split_on_char ' '
        |> List.filter (fun token -> not (String.equal token ""))
      in

      match tokens with
      | [ rows; columns ] ->
          Some
            {
              Sessy_ui.width = int_of_string columns;
              height = int_of_string rows;
            }
      | _ -> None
    with End_of_file | Failure _ -> None
  in

  let _ = Unix.close_process_in process in

  parsed |> Option.value ~default:default_terminal

let sync_terminal (model : Sessy_ui.model) =
  let terminal = terminal_size () in

  if
    Int.equal terminal.width model.terminal.width
    && Int.equal terminal.height model.terminal.height
  then model
  else Sessy_ui.update model (Sessy_ui.Window_resized terminal) |> fst

let selected_session_id (model : Sessy_ui.model) =
  match List.nth_opt model.results model.cursor with
  | Some (ranked : ranked) -> Some ranked.session.id
  | None -> None

let preview_is_current (model : Sessy_ui.model) session_id =
  match model.preview with
  | Some preview -> Session_id.equal preview.session.id session_id
  | None -> false

let sync_preview handlers (model : Sessy_ui.model) =
  if not model.preview_visible then model
  else
    match selected_session_id model with
    | None -> Sessy_ui.update model (Sessy_ui.Preview_loaded None) |> fst
    | Some session_id when preview_is_current model session_id -> model
    | Some session_id -> (
        match handlers.resolve_preview session_id with
        | Ok preview ->
            Sessy_ui.update model (Sessy_ui.Preview_loaded (Some preview))
            |> fst
        | Error message ->
            Sessy_ui.update model (Sessy_ui.Notice_set (Some message)) |> fst)

let render (model : Sessy_ui.model) =
  output_string Stdlib.stdout "\027[H\027[2J";
  output_string Stdlib.stdout (Sessy_ui.view model);
  output_string Stdlib.stdout "\027[0J";
  flush Stdlib.stdout

let read_char fd =
  let buffer = Bytes.create 1 in

  match Unix.read fd buffer 0 1 with
  | 0 -> None
  | _ -> Some (Bytes.get buffer 0)

let read_char_if_ready fd timeout =
  match Unix.select [ fd ] [] [] timeout with
  | [], _, _ -> None
  | _ -> read_char fd

let drop_last text =
  match String.length text with
  | 0 -> ""
  | length -> String.sub text 0 (length - 1)

let append_char text char = text ^ String.make 1 char

let decode_input (model : Sessy_ui.model) = function
  | '\r' | '\n' -> Some Sessy_ui.Session_selected
  | '\t' -> Some Sessy_ui.Preview_toggled
  | '\127' | '\008' ->
      let text = model.query.text |> drop_last in

      Some (Sessy_ui.Query_changed text)
  | '?' -> Some Sessy_ui.Help_toggled
  | char -> (
      match Char.code char with
      | 3 -> Some Sessy_ui.Quit
      | 6 -> Some Sessy_ui.Search_mode_toggled
      | 15 -> Some Sessy_ui.Open_directory_requested
      | 18 -> Some Sessy_ui.Reload_requested
      | 19 -> Some Sessy_ui.Scope_toggled
      | 20 -> Some Sessy_ui.Tool_filter_toggled
      | 25 -> Some Sessy_ui.Copy_requested
      | code when code >= 32 && code <= 126 ->
          let text = char |> append_char model.query.text in

          Some (Sessy_ui.Query_changed text)
      | _ -> None)

let read_message fd (model : Sessy_ui.model) =
  match read_char fd with
  | None -> Some Sessy_ui.Quit
  | Some '\027' -> (
      match (read_char_if_ready fd 0.01, read_char_if_ready fd 0.01) with
      | Some '[', Some 'A' -> Some (Sessy_ui.Cursor_moved (-1))
      | Some '[', Some 'B' -> Some (Sessy_ui.Cursor_moved 1)
      | _ -> Some Sessy_ui.Quit)
  | Some char -> char |> decode_input model

let notice_message result =
  match result with Ok notice -> notice | Error message -> Some message

let rec resolve_command handlers (model : Sessy_ui.model) command =
  match command with
  | Sessy_ui.Noop -> Continue model
  | Sessy_ui.Exit -> Finish `Exit
  | Sessy_ui.Launch command -> Finish (`Launch command)
  | Sessy_ui.Copy_to_clipboard text ->
      let notice = text |> handlers.copy_to_clipboard |> notice_message in

      let model, command = Sessy_ui.update model (Sessy_ui.Notice_set notice) in

      resolve_command handlers model command
  | Sessy_ui.Open_directory path ->
      let notice = path |> handlers.open_directory |> notice_message in

      let model, command = Sessy_ui.update model (Sessy_ui.Notice_set notice) in

      resolve_command handlers model command
  | Sessy_ui.Resolve_open_directory session_id ->
      let notice =
        session_id |> handlers.open_session_directory |> notice_message
      in

      let model, command = Sessy_ui.update model (Sessy_ui.Notice_set notice) in

      resolve_command handlers model command
  | Sessy_ui.Reload_index -> (
      match handlers.reload_snapshot () with
      | Ok snapshot ->
          let model, command =
            Sessy_ui.update model (Sessy_ui.Reload_finished snapshot)
          in

          resolve_command handlers model command
      | Error message ->
          let model, command =
            Sessy_ui.update model (Sessy_ui.Notice_set (Some message))
          in

          resolve_command handlers model command)
  | Sessy_ui.Print_notice message ->
      let model, command =
        Sessy_ui.update model (Sessy_ui.Notice_set (Some message))
      in

      resolve_command handlers model command
  | Sessy_ui.Print_error message ->
      let model, command =
        Sessy_ui.update model (Sessy_ui.Notice_set (Some message))
      in

      resolve_command handlers model command
  | Sessy_ui.Resolve_resume (session_id, launch_mode) -> (
      match handlers.resolve_launch session_id launch_mode with
      | Ok command -> Finish (`Launch command)
      | Error message ->
          let model, command =
            Sessy_ui.update model (Sessy_ui.Notice_set (Some message))
          in

          resolve_command handlers model command)
  | Sessy_ui.Print_sessions _ | Sessy_ui.Print_preview _
  | Sessy_ui.Resolve_last _ | Sessy_ui.Resolve_preview _ | Sessy_ui.Run_doctor
    ->
      let model, command =
        Sessy_ui.update model
          (Sessy_ui.Notice_set
             (Some "unexpected CLI command reached the interactive runtime"))
      in

      resolve_command handlers model command

let step handlers (model : Sessy_ui.model) message =
  let model, command = Sessy_ui.update model message in

  resolve_command handlers model command

let rec loop handlers (model : Sessy_ui.model) =
  let model = model |> sync_terminal |> sync_preview handlers in

  render model;

  match read_message tty_in model with
  | None -> loop handlers model
  | Some message -> (
      match step handlers model message with
      | Continue model -> loop handlers model
      | Finish outcome -> outcome)

let run ~index ~config ~cwd ~repo_root ~now ~notice ~handlers =
  let initial_terminal = terminal_size () in
  let initial_model =
    Sessy_ui.init index config ~cwd ~repo_root ~now ~terminal:initial_terminal
      ~notice
  in
  let original_terminal = prepare_terminal tty_in in

  Fun.protect
    ~finally:(fun () -> Unix.tcsetattr tty_in Unix.TCSAFLUSH original_terminal)
    (fun () -> with_alt_screen (fun () -> loop handlers initial_model))
