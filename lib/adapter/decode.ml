open Sessy_domain

let non_empty_lines raw =
  raw |> String.split_on_char '\n' |> List.map String.trim
  |> List.filter (fun line -> not (String.equal line ""))

let collapse_whitespace value =
  let buffer = Buffer.create (String.length value) in
  let pending_space = ref false in

  value
  |> String.iter (fun character ->
      if Char.code character <= 32 then
        pending_space := Buffer.length buffer > 0
      else (
        if !pending_space then Buffer.add_char buffer ' ';
        pending_space := false;
        Buffer.add_char buffer character));

  Buffer.contents buffer

let normalize_text value =
  value |> collapse_whitespace |> String.trim |> function
  | "" -> None
  | text -> Some text

let parse_json line =
  try Ok (Yojson.Safe.from_string line)
  with Yojson.Json_error message -> Error (Invalid_json message)

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let rec field_path path json =
  match path with
  | [] -> Some json
  | name :: rest -> (
      match field name json with
      | Some child -> field_path rest child
      | None -> None)

let string_value = function `String value -> Some value | _ -> None
let first_some values = values |> List.find_map Fun.id

let string_path path json =
  match field_path path json with
  | Some value -> string_value value
  | None -> None

let rec text_fragments = function
  | `String value -> [ value ]
  | `List values -> values |> List.map text_fragments |> List.flatten
  | `Assoc _ as json ->
      [ [ "text" ]; [ "content" ]; [ "message" ]; [ "payload" ] ]
      |> List.map (fun path -> field_path path json)
      |> List.filter_map Fun.id |> List.map text_fragments |> List.flatten
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `Tuple _ | `Variant _ ->
      []

let text_value json =
  json |> text_fragments |> List.filter_map normalize_text |> function
  | [] -> None
  | fragments -> fragments |> String.concat "\n" |> normalize_text

let integer_slice value start length =
  if String.length value < start + length then None
  else String.sub value start length |> int_of_string_opt

let float_suffix value start length =
  if length <= 0 then Some 0.
  else
    String.sub value start length
    |> Printf.sprintf "0.%s" |> float_of_string_opt

let days_from_civil year month day =
  let adjusted_year = if month <= 2 then year - 1 else year in
  let era =
    if adjusted_year >= 0 then adjusted_year / 400
    else (adjusted_year - 399) / 400
  in
  let year_of_era = adjusted_year - (era * 400) in
  let month_prime = if month > 2 then month - 3 else month + 9 in
  let day_of_year = (((153 * month_prime) + 2) / 5) + day - 1 in
  let day_of_era =
    (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year
  in

  (era * 146_097) + day_of_era - 719_468

let parse_iso8601_utc value =
  let min_length = 20 in

  if String.length value < min_length then None
  else if not (Char.equal value.[4] '-') then None
  else if not (Char.equal value.[7] '-') then None
  else if not (Char.equal value.[10] 'T') then None
  else if not (Char.equal value.[13] ':') then None
  else if not (Char.equal value.[16] ':') then None
  else
    let year = integer_slice value 0 4 in
    let month = integer_slice value 5 2 in
    let day = integer_slice value 8 2 in
    let hour = integer_slice value 11 2 in
    let minute = integer_slice value 14 2 in
    let second = integer_slice value 17 2 in
    let fraction =
      if String.length value = min_length && Char.equal value.[19] 'Z' then
        Some 0.
      else if String.length value > min_length && Char.equal value.[19] '.' then
        match String.index_from_opt value 20 'Z' with
        | Some z_index -> float_suffix value 20 (z_index - 20)
        | None -> None
      else None
    in

    match (year, month, day, hour, minute, second, fraction) with
    | ( Some year,
        Some month,
        Some day,
        Some hour,
        Some minute,
        Some second,
        Some fraction ) ->
        let days = days_from_civil year month day in
        let whole_seconds =
          (days * 86_400) + (hour * 3_600) + (minute * 60) + second
        in

        Some (float_of_int whole_seconds +. fraction)
    | _ -> None

let normalize_epoch_seconds value =
  if value > 10_000_000_000. then value /. 1000. else value

let parse_timestamp_value = function
  | `Float value -> Some (normalize_epoch_seconds value)
  | `Int value -> Some (value |> float_of_int |> normalize_epoch_seconds)
  | `Intlit value ->
      value |> float_of_string_opt |> Option.map normalize_epoch_seconds
  | `String value -> (
      let numeric =
        value |> String.trim |> float_of_string_opt
        |> Option.map normalize_epoch_seconds
      in

      match numeric with Some _ -> numeric | None -> parse_iso8601_utc value)
  | `Assoc _ | `Bool _ | `List _ | `Null | `Tuple _ | `Variant _ -> None

let timestamp_path path json =
  match field_path path json with
  | Some value -> parse_timestamp_value value
  | None -> None

let session_id_path path json =
  match string_path path json with
  | Some value -> Session_id.of_string value
  | None -> None
