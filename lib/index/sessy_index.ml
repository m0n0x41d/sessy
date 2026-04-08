open Sessy_domain
module Session_map = Map.Make (String)

type t = { sessions : session list }

let empty = { sessions = [] }
let session_key session = session.id |> Session_id.to_string

let compare_sessions left right =
  let updated_order = Float.compare right.updated_at left.updated_at in

  if updated_order <> 0 then updated_order
  else Session_id.compare left.id right.id

let most_recent_session left right =
  if Float.compare left.updated_at right.updated_at >= 0 then left else right

let build sessions =
  let deduplicated =
    sessions
    |> List.fold_left
         (fun sessions_by_id session ->
           sessions_by_id
           |> Session_map.update (session_key session) (fun current ->
               current
               |> Option.map (most_recent_session session)
               |> Option.value ~default:session
               |> Option.some))
         Session_map.empty
    |> Session_map.bindings |> List.map snd |> List.sort compare_sessions
  in

  { sessions = deduplicated }

let all_sessions index = index.sessions
let count index = index.sessions |> List.length

let find_by_id index session_id =
  index.sessions
  |> List.find_opt (fun session -> Session_id.equal session.id session_id)

let search index query ~now ~cwd ~repo_root =
  index |> all_sessions
  |> Sessy_core.filter_tool query.tool_filter
  |> Sessy_core.filter_scope query.scope ~cwd ~repo_root
  |> List.filter_map (Sessy_core.rank query ~now ~cwd ~repo_root)
  |> Sessy_core.sort_ranked

let refresh _ sessions = build sessions
