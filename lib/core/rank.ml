open Sessy_domain

type signal = { weight : float; match_kind : match_kind }

let exact_cwd_weight = 10_000.
let same_repo_weight = 5_000.
let active_weight = 3_000.
let id_prefix_weight = 2_000.
let substring_weight = 1_000.
let fuzzy_weight = 500.
let normalized_query query = query |> String.trim |> String.lowercase_ascii

let normalize_repo_root repo_root =
  let length = String.length repo_root in

  if length > 1 && String.ends_with ~suffix:"/" repo_root then
    String.sub repo_root 0 (length - 1)
  else repo_root

let path_in_repo ~repo_root path =
  let normalized_root = normalize_repo_root repo_root in

  String.equal path normalized_root
  || String.starts_with ~prefix:(normalized_root ^ "/") path

let contains_substring ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in

  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > haystack_length then false
    else if String.sub haystack index needle_length = needle then true
    else loop (index + 1)
  in

  loop 0

let searchable_fields session =
  [
    Session_id.to_string session.id;
    Option.value ~default:"" session.title;
    Option.value ~default:"" session.first_prompt;
    session.cwd;
    Option.value ~default:"" session.project_key;
  ]

let searchable_text session = session |> searchable_fields |> String.concat "\n"

let check_exact_cwd cwd (session : session) =
  if String.equal session.cwd cwd then
    Some { weight = exact_cwd_weight; match_kind = Exact_cwd }
  else None

let check_same_repo repo_root (session : session) =
  match repo_root with
  | Some root when path_in_repo ~repo_root:root session.cwd ->
      Some { weight = same_repo_weight; match_kind = Same_repo }
  | Some _ | None -> None

let check_active session =
  if session.is_active then Some { weight = active_weight; match_kind = Active }
  else None

let check_id_prefix query_text session =
  if String.length query_text = 0 then None
  else
    let matches =
      session.id |> Session_id.to_string |> String.lowercase_ascii
      |> String.starts_with ~prefix:query_text
    in

    if matches then Some { weight = id_prefix_weight; match_kind = Id_prefix }
    else None

let check_substring query_text session =
  if String.length query_text = 0 then None
  else
    let matches =
      session |> searchable_fields
      |> List.map String.lowercase_ascii
      |> List.exists (contains_substring ~needle:query_text)
    in

    if matches then Some { weight = substring_weight; match_kind = Substring }
    else None

let check_fuzzy query_text session =
  if String.length query_text = 0 then None
  else
    let haystack = searchable_text session in

    Fuzzy.fuzzy_score ~pattern:query_text ~haystack
    |> Option.map (fun score ->
        { weight = fuzzy_weight *. score; match_kind = Fuzzy })

let compute_signals query_text ~cwd ~repo_root session =
  [
    check_exact_cwd cwd session;
    check_same_repo repo_root session;
    check_active session;
    check_id_prefix query_text session;
    check_substring query_text session;
    check_fuzzy query_text session;
  ]
  |> List.filter_map Fun.id

let aggregate signals =
  signals |> List.fold_left (fun total signal -> total +. signal.weight) 0.

let best_signal signals =
  match signals with
  | [] -> None
  | head :: tail ->
      tail
      |> List.fold_left
           (fun best candidate ->
             if Float.compare candidate.weight best.weight > 0 then candidate
             else best)
           head
      |> fun strongest -> Some strongest.match_kind

let recency_bonus ~now updated_at =
  let age_hours =
    now -. updated_at |> Float.max 0. |> fun seconds -> seconds /. 3600.
  in

  200. *. Float.exp (-.age_hours /. 168.)

let resolve_match_kind query_text signals =
  match signals with
  | [] when String.length query_text = 0 -> Recency
  | [] -> Recency
  | _ -> signals |> best_signal |> Option.value ~default:Recency

let rank query ~now ~cwd ~repo_root session =
  let query_text = query.text |> normalized_query in

  let signals = session |> compute_signals query_text ~cwd ~repo_root in

  match (String.length query_text = 0, signals) with
  | false, [] -> None
  | _, _ ->
      Some
        {
          session;
          score = aggregate signals +. recency_bonus ~now session.updated_at;
          match_kind = resolve_match_kind query_text signals;
        }

let sort_ranked ranked_sessions =
  ranked_sessions
  |> List.stable_sort (fun left right -> Float.compare right.score left.score)

let filter_scope scope ~cwd ~repo_root (sessions : session list) =
  sessions
  |> List.filter (fun (session : session) ->
      match scope with
      | Cwd -> String.equal session.cwd cwd
      | Repo ->
          repo_root
          |> Option.map (fun root -> path_in_repo ~repo_root:root session.cwd)
          |> Option.value ~default:true
      | All -> true)

let filter_tool tool_filter (sessions : session list) =
  sessions
  |> List.filter (fun (session : session) ->
      tool_filter
      |> Option.map (Tool.equal session.tool)
      |> Option.value ~default:true)
