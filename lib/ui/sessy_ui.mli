type output_format =
  | Plain
  | Json

type cli_action =
  | Open_picker
  | List_sessions of output_format

type cmd =
  | Print_sessions of Sessy_domain.session list * output_format
  | Print_error of string

val parse_cli : string list -> (cli_action, string) result

val dispatch :
  cli_action ->
  Sessy_index.t ->
  Sessy_domain.config ->
  cwd:string ->
  cmd list

val format_session_plain : now:float -> Sessy_domain.session -> string
val format_session_json : Sessy_domain.session -> Yojson.Safe.t

val format_sessions :
  now:float -> output_format -> Sessy_domain.session list -> string
