val read_file : string -> (string, [> `Io_error of string ]) result
val list_dir : string -> (string list, [> `Io_error of string ]) result
val file_exists : string -> bool
val expand_home : string -> string
val detect_git_root : string -> string option
val load_config : unit -> Sessy_domain.config
val load_config_from_paths : string list -> Sessy_domain.config * string list

val load_sessions :
  Sessy_domain.config -> Sessy_domain.session list * string list

val doctor_report :
  config_paths:string list ->
  config:Sessy_domain.config ->
  config_warnings:string list ->
  string

val spawn : Sessy_domain.launch_cmd -> (unit, [> `Exec_error of string ]) result
val exec_replace :
  Sessy_domain.launch_cmd -> (unit, [> `Exec_error of string ]) result
val print_cmd : Sessy_domain.launch_cmd -> unit
val run_once :
  argv:string list -> config_paths:string list -> cwd:string -> now:float -> int
val run : unit -> unit
