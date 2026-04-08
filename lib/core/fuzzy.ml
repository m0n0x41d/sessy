let lower value = value |> String.lowercase_ascii

let is_boundary_char = function
  | '/' | '_' | '-' | ' ' | '.' | ':' -> true
  | _ -> false

let is_word_boundary haystack index =
  index = 0 || is_boundary_char haystack.[index - 1]

let find_next haystack target start =
  let haystack_length = String.length haystack in

  let rec loop index =
    if index >= haystack_length then None
    else if Char.equal haystack.[index] target then Some index
    else loop (index + 1)
  in

  loop start

let collect_positions pattern haystack =
  let pattern_length = String.length pattern in

  let rec loop pattern_index haystack_index positions =
    if pattern_index >= pattern_length then Some (List.rev positions)
    else
      match find_next haystack pattern.[pattern_index] haystack_index with
      | None -> None
      | Some matched_index ->
          loop (pattern_index + 1) (matched_index + 1)
            (matched_index :: positions)
  in

  loop 0 0 []

let count_consecutive positions =
  let rec loop previous remaining count =
    match remaining with
    | [] -> count
    | current :: tail ->
        let next_count = if current = previous + 1 then count + 1 else count in

        loop current tail next_count
  in

  match positions with [] -> 0 | head :: tail -> loop head tail 0

let count_boundaries haystack positions =
  positions |> List.filter (is_word_boundary haystack) |> List.length

let clamp score = score |> Float.max 0. |> Float.min 1.

let fuzzy_score ~pattern ~haystack =
  let normalized_pattern = pattern |> lower in

  let normalized_haystack = haystack |> lower in

  match
    (String.length normalized_pattern, String.length normalized_haystack)
  with
  | 0, _ -> Some 1.
  | _, 0 -> None
  | pattern_length, haystack_length ->
      normalized_haystack
      |> collect_positions normalized_pattern
      |> Option.map (fun positions ->
          let base_score =
            float_of_int pattern_length /. float_of_int haystack_length
          in
          let consecutive_bonus =
            match pattern_length with
            | 0 | 1 -> 0.
            | _ ->
                positions |> count_consecutive |> float_of_int |> fun count ->
                count /. float_of_int (pattern_length - 1) |> ( *. ) 0.25
          in
          let boundary_bonus =
            positions |> count_boundaries normalized_haystack |> float_of_int
            |> fun count -> count /. float_of_int pattern_length |> ( *. ) 0.1
          in

          base_score +. consecutive_bonus +. boundary_bonus |> clamp)
