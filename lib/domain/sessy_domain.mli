type tool =
  | Claude
  | Codex

module Tool : sig
  type t = tool =
    | Claude
    | Codex

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val to_string : t -> string
end

module Session_id : sig
  type t

  val of_string : string -> t option
  val to_string : t -> string
  val short : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

type session = {
  id : Session_id.t;
  tool : tool;
  title : string option;
  first_prompt : string option;
  cwd : string;
  project_key : string option;
  model : string option;
  updated_at : float;
  is_active : bool;
}

type scope =
  | Cwd
  | Repo
  | All

type search_mode =
  | Meta
  | Deep

type query = {
  text : string;
  scope : scope;
  tool_filter : tool option;
  mode : search_mode;
}

type match_kind =
  | Exact_cwd
  | Same_repo
  | Active
  | Id_prefix
  | Substring
  | Fuzzy

type ranked = {
  session : session;
  score : float;
  match_kind : match_kind;
}

type exec_mode =
  | Spawn
  | Exec
  | Print

type launch_cmd = {
  argv : string * string list;
  cwd : string;
  exec_mode : exec_mode;
  display : string;
}

type cwd_policy = [ `Session | `Current ]

type launch_template = {
  argv_template : string list;
  cwd_policy : cwd_policy;
  default_exec_mode : exec_mode;
}

type profile = {
  name : string;
  base_tool : tool;
  argv_append : string list;
  exec_mode_override : exec_mode option;
}

type source_config = {
  tool : tool;
  history_path : string;
  projects_path : string option;
  sessions_path : string option;
}

type config = {
  default_scope : scope;
  preview : bool;
  sources : source_config list;
  launches : (tool * launch_template) list;
  profiles : profile list;
}

type parse_error =
  | Invalid_json of string
  | Missing_field of string
  | Invalid_format of string

type config_error =
  | File_not_found of string
  | Parse_failed of string
  | Invalid_value of string * string
