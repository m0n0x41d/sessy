open Sessy_domain

let tool = Claude
let history_session_id_paths = [ [ "sessionId" ] ]
let history_title_paths = [ [ "display" ]; [ "displayTitle" ]; [ "title" ] ]
let history_cwd_paths = [ [ "project" ]; [ "projectKey" ]; [ "cwd" ] ]
let history_timestamp_paths = [ [ "timestamp" ]; [ "lastModified" ] ]
let history_model_paths = [ [ "model" ] ]

let first_string paths json =
  paths
  |> List.map (fun path -> Decode.string_path path json)
  |> Decode.first_some
  |> function
  | Some value -> Decode.normalize_text value
  | None -> None

let first_timestamp paths json =
  paths
  |> List.map (fun path -> Decode.timestamp_path path json)
  |> Decode.first_some

let history_entry json =
  let id =
    history_session_id_paths
    |> List.map (fun path -> Decode.session_id_path path json)
    |> Decode.first_some
  in

  id
  |> Option.map (fun session_id ->
      let cwd =
        json |> first_string history_cwd_paths |> Option.value ~default:""
      in
      let title = json |> first_string history_title_paths in
      let updated_at =
        json
        |> first_timestamp history_timestamp_paths
        |> Option.value ~default:0.
      in

      {
        id = session_id;
        tool;
        title;
        first_prompt = title;
        cwd;
        project_key = Decode.normalize_text cwd;
        model = first_string history_model_paths json;
        updated_at;
        is_active = false;
      })

let parse_history raw =
  let lines = raw |> Decode.non_empty_lines in
  let sessions =
    lines
    |> List.filter_map (fun line ->
        line |> Decode.parse_json |> function
        | Ok json -> history_entry json
        | Error _ -> None)
  in

  match (lines, sessions) with
  | [], _ -> Ok []
  | _ :: _, [] -> Error (Invalid_format "no parseable Claude history entries")
  | _ -> Ok sessions

let has_type expected json =
  json
  |> Decode.string_path [ "type" ]
  |> Option.map (String.equal expected)
  |> Option.value ~default:false

let detail_prompt json =
  if not (has_type "user" json) then None
  else
    match Decode.field_path [ "message"; "content" ] json with
    | Some value -> Decode.text_value value
    | None -> None

let detail_model json =
  if not (has_type "assistant" json) then None
  else json |> first_string [ [ "message"; "model" ]; [ "model" ] ]

let parse_detail raw =
  let lines = raw |> Decode.non_empty_lines in
  let jsons =
    lines
    |> List.filter_map (fun line ->
        line |> Decode.parse_json |> Result.to_option)
  in
  let session_id =
    jsons
    |> List.find_map (fun json -> Decode.session_id_path [ "sessionId" ] json)
  in
  let cwd = jsons |> List.find_map (first_string history_cwd_paths) in
  let first_prompt = jsons |> List.find_map detail_prompt in
  let updated_at =
    jsons
    |> List.filter_map (first_timestamp history_timestamp_paths)
    |> List.sort Float.compare |> List.rev
    |> function
    | first :: _ -> Some first
    | [] -> None
  in
  let model = jsons |> List.find_map detail_model in

  match (lines, jsons, session_id, cwd, updated_at) with
  | [], _, _, _, _ -> Error (Invalid_format "Claude detail is empty")
  | _ :: _, [], _, _, _ ->
      Error (Invalid_json "Claude detail contains no valid JSON lines")
  | _ :: _, _ :: _, None, _, _ -> Error (Missing_field "sessionId")
  | _ :: _, _ :: _, Some _, None, _ -> Error (Missing_field "cwd")
  | _ :: _, _ :: _, Some _, Some _, None -> Error (Missing_field "timestamp")
  | _ :: _, _ :: _, Some id, Some cwd, Some updated_at ->
      Ok
        {
          id;
          tool;
          title = first_prompt;
          first_prompt;
          cwd;
          project_key = Decode.normalize_text cwd;
          model;
          updated_at;
          is_active = false;
        }
