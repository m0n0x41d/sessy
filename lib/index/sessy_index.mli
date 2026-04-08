type t

val empty : t
val build : Sessy_domain.session list -> t

val search :
  t ->
  Sessy_domain.query ->
  now:float ->
  cwd:string ->
  repo_root:string option ->
  Sessy_domain.ranked list

val find_by_id :
  t -> Sessy_domain.Session_id.t -> Sessy_domain.session option

val count : t -> int
val all_sessions : t -> Sessy_domain.session list
val refresh : t -> Sessy_domain.session list -> t
