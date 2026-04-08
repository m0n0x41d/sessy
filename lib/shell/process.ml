open Sessy_domain

let exec_error message = Error (`Exec_error message)

let argv_list command = let head, tail = command.argv in

                        head :: tail

let argv_array command = command |> argv_list |> Array.of_list

let with_cwd cwd work =
  let original_cwd = Sys.getcwd () in

  Unix.chdir cwd;
  Fun.protect ~finally:(fun () -> Unix.chdir original_cwd) work

let describe_unix_error error function_name argument =
  Printf.sprintf "%s(%s): %s" function_name argument (Unix.error_message error)

let spawn command =
  let head, _ = command.argv in
  let argv = argv_array command in

  try
    with_cwd command.cwd (fun () ->
        let pid =
          Unix.create_process head argv Unix.stdin Unix.stdout Unix.stderr
        in

        match Unix.waitpid [] pid with
        | _, Unix.WEXITED 0 -> Ok ()
        | _, Unix.WEXITED code ->
            exec_error (Printf.sprintf "process exited with status %d" code)
        | _, Unix.WSIGNALED signal ->
            exec_error (Printf.sprintf "process killed by signal %d" signal)
        | _, Unix.WSTOPPED signal ->
            exec_error (Printf.sprintf "process stopped by signal %d" signal))
  with Unix.Unix_error (error, function_name, argument) ->
    exec_error (describe_unix_error error function_name argument)

let exec_replace command =
  let head, _ = command.argv in
  let argv = argv_array command in

  try with_cwd command.cwd (fun () -> Unix.execvp head argv)
  with Unix.Unix_error (error, function_name, argument) ->
    failwith (describe_unix_error error function_name argument)

let print_cmd command = print_endline command.display
