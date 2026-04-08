open Sessy_domain

let tool = Codex
let history_session_id_paths = [ [ "session_id" ]; [ "sessionId" ] ]
let history_title_paths = [ [ "text" ]; [ "prompt" ]; [ "display" ] ]
let history_cwd_paths = [ [ "cwd" ]; [ "project" ]; [ "projectKey" ] ]
let history_timestamp_paths = [ [ "ts" ]; [ "timestamp" ] ]
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
  | _ :: _, [] -> Error (Invalid_format "no parseable Codex history entries")
  | _ -> Ok sessions

let has_type expected json =
  json
  |> Decode.string_path [ "type" ]
  |> Option.map (String.equal expected)
  |> Option.value ~default:false

let payload_string paths json =
  paths
  |> List.map (fun path -> Decode.string_path path json)
  |> Decode.first_some
  |> function
  | Some value -> Decode.normalize_text value
  | None -> None

let first_string_across_jsons paths jsons =
  paths
  |> List.find_map (fun path ->
      jsons |> List.find_map (payload_string [ path ]))

let detail_prompt json =
  let is_user_message =
    has_type "response_item" json
    && json
       |> Decode.string_path [ "payload"; "role" ]
       |> Option.map (String.equal "user")
       |> Option.value ~default:false
  in

  if not is_user_message then None
  else
    match Decode.field_path [ "payload"; "content" ] json with
    | Some value -> Decode.text_value value
    | None -> None

let parse_detail raw =
  let lines = raw |> Decode.non_empty_lines in
  let jsons =
    lines
    |> List.filter_map (fun line ->
        line |> Decode.parse_json |> Result.to_option)
  in
  let session_id =
    jsons
    |> List.find_map (fun json ->
        Decode.session_id_path [ "payload"; "id" ] json)
  in
  let cwd =
    jsons
    |> List.find_map
         (payload_string [ [ "payload"; "cwd" ]; [ "cwd" ]; [ "project" ] ])
  in
  let first_prompt = jsons |> List.find_map detail_prompt in
  let updated_at =
    jsons
    |> List.filter_map (first_timestamp [ [ "timestamp" ]; [ "ts" ] ])
    |> List.sort Float.compare |> List.rev
    |> function
    | first :: _ -> Some first
    | [] -> None
  in
  let model =
    jsons
    |> first_string_across_jsons
         [
           [ "payload"; "model" ]; [ "model" ]; [ "payload"; "model_provider" ];
         ]
  in

  match (lines, jsons, session_id, cwd, updated_at) with
  | [], _, _, _, _ -> Error (Invalid_format "Codex detail is empty")
  | _ :: _, [], _, _, _ ->
      Error (Invalid_json "Codex detail contains no valid JSON lines")
  | _ :: _, _ :: _, None, _, _ -> Error (Missing_field "payload.id")
  | _ :: _, _ :: _, Some _, None, _ -> Error (Missing_field "payload.cwd")
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
