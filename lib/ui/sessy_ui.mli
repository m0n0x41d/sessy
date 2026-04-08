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

type cmd =
  | Print_notice of string
  | Print_sessions of Sessy_domain.session list * output_format
  | Resolve_last of launch_mode
  | Resolve_resume of Sessy_domain.Session_id.t * launch_mode
  | Resolve_preview of Sessy_domain.Session_id.t
  | Run_doctor
  | Print_error of string

val parse_cli : string list -> (cli_action, string) result

val dispatch :
  cli_action -> Sessy_index.t -> Sessy_domain.config -> cwd:string -> cmd list

val format_session_plain : now:float -> Sessy_domain.session -> string
val format_session_json : Sessy_domain.session -> Yojson.Safe.t
val format_preview : now:float -> preview -> string

val format_sessions :
  now:float -> output_format -> Sessy_domain.session list -> string
