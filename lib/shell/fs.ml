let io_error message = Error (`Io_error message)

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error message -> io_error message

let list_dir path =
  try
    path
    |> Sys.readdir
    |> Array.to_list
    |> List.sort String.compare
    |> Result.ok
  with Sys_error message -> io_error message

let file_exists path = Sys.file_exists path

let expand_home path =
  let home =
    match Sys.getenv_opt "HOME" with
    | Some value when not (String.equal value "") -> Some value
    | Some _ | None -> None
  in

  if String.equal path "~" then home |> Option.value ~default:path
  else if String.starts_with ~prefix:"~/" path then
    home
    |> Option.map (fun value -> value ^ String.sub path 1 (String.length path - 1))
    |> Option.value ~default:path
  else path

let rec detect_git_root path =
  let candidate = Filename.concat path ".git" in
  let parent = Filename.dirname path in

  if file_exists candidate then Some path
  else if String.equal parent path then None
  else detect_git_root parent
