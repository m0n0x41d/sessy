type output_format = Plain | Json
type launch_mode = Default | Dry_run

type cli_action =
  | Open_picker
  | List_sessions of output_format
  | Resume_last of launch_mode
  | Resume_id of Sessy_domain.Session_id.t * launch_mode
  | Preview_session of Sessy_domain.Session_id.t
  | Doctor

type preview = {
  session : Sessy_domain.session;
  launch : (Sessy_domain.launch_cmd, string) result;
}

type terminal = { width : int; height : int }

type model = {
  index : Sessy_index.t;
  config : Sessy_domain.config;
  query : Sessy_domain.query;
  results : Sessy_domain.ranked list;
  cursor : int;
  preview_visible : bool;
  help_visible : bool;
  preview : preview option;
  cwd : string;
  repo_root : string option;
  now : float;
  terminal : terminal;
  notice : string option;
}

type reload_snapshot = {
  index : Sessy_index.t;
  config : Sessy_domain.config;
  now : float;
  warning : string option;
}

type cmd =
  | Launch of Sessy_domain.launch_cmd
  | Copy_to_clipboard of string
  | Open_directory of string
  | Resolve_open_directory of Sessy_domain.Session_id.t
  | Reload_index
  | Exit
  | Noop
  | Print_notice of string
  | Print_sessions of Sessy_domain.session list * output_format
  | Print_preview of preview
  | Resolve_last of launch_mode
  | Resolve_resume of Sessy_domain.Session_id.t * launch_mode
  | Resolve_preview of Sessy_domain.Session_id.t
  | Run_doctor
  | Print_error of string

type msg =
  | Query_changed of string
  | Cursor_moved of int
  | Scope_toggled
  | Tool_filter_toggled
  | Search_mode_toggled
  | Preview_toggled
  | Help_toggled
  | Session_selected
  | Copy_requested
  | Open_directory_requested
  | Reload_requested
  | Reload_finished of reload_snapshot
  | Preview_loaded of preview option
  | Notice_set of string option
  | Window_resized of terminal
  | Quit

val init :
  Sessy_index.t ->
  Sessy_domain.config ->
  cwd:string ->
  repo_root:string option ->
  now:float ->
  terminal:terminal ->
  notice:string option ->
  model

val update : model -> msg -> model * cmd
val view : model -> string
val selected_preview : model -> preview option
val parse_cli : string list -> (cli_action, string) result

val dispatch :
  cli_action -> Sessy_index.t -> Sessy_domain.config -> cwd:string -> cmd list

val format_session_plain : now:float -> Sessy_domain.session -> string
val format_session_json : Sessy_domain.session -> Yojson.Safe.t
val format_preview : now:float -> preview -> string

val format_sessions :
  now:float -> output_format -> Sessy_domain.session list -> string
