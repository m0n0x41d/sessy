val default_config : Sessy_domain.config

val merge_config :
  Sessy_domain.config -> Sessy_domain.config -> Sessy_domain.config

val resolve_config : Sessy_domain.config list -> Sessy_domain.config

val expand_template :
  Sessy_domain.session ->
  Sessy_domain.profile option ->
  Sessy_domain.launch_template ->
  (Sessy_domain.launch_cmd, Sessy_domain.config_error) result

val fuzzy_score : pattern:string -> haystack:string -> float option

val rank :
  Sessy_domain.query ->
  now:float ->
  cwd:string ->
  repo_root:string option ->
  Sessy_domain.session ->
  Sessy_domain.ranked option

val sort_ranked : Sessy_domain.ranked list -> Sessy_domain.ranked list

val filter_scope :
  Sessy_domain.scope ->
  cwd:string ->
  repo_root:string option ->
  Sessy_domain.session list ->
  Sessy_domain.session list

val filter_tool :
  Sessy_domain.tool option ->
  Sessy_domain.session list ->
  Sessy_domain.session list
