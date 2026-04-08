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
  let home = Sys.getenv_opt "HOME" |> Option.value ~default:"" in

  if String.equal path "~" then home
  else if String.starts_with ~prefix:"~/" path then
    home ^ String.sub path 1 (String.length path - 1)
  else path

let rec detect_git_root path =
  let candidate = Filename.concat path ".git" in
  let parent = Filename.dirname path in

  if file_exists candidate then Some path
  else if String.equal parent path then None
  else detect_git_root parent
