open Alcotest
open Sessy_domain

let require_some label option_value =
  option_value |> function Some value -> value | None -> fail label

let with_temp_file contents run =
  let path = Filename.temp_file "sessy-config-" ".toml" in

  Out_channel.with_open_bin path (fun channel -> output_string channel contents);

  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> run path)

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

let test_profile_fallback_preserves_section_identity_with_extends () =
  let base_config =
    {|
[profiles.claude.fast]
extends = "codex"
argv_append = ["--profile", "fast"]
exec_mode = "exec"
|}
  in
  let invalid_override =
    {|
[profiles.claude.fast]
argv_append = "skip"
|}
  in

  with_temp_file base_config (fun base_path ->
      with_temp_file invalid_override (fun override_path ->
          let config, warnings =
            Sessy_shell.load_config_from_paths [ base_path; override_path ]
          in
          let fast_profiles =
            config.profiles
            |> List.filter (fun profile -> String.equal profile.name "fast")
          in
          let fast_profile =
            fast_profiles
            |> List.find_opt (fun profile -> Tool.equal profile.base_tool Codex)
            |> require_some "expected Codex-backed fast profile"
          in

          check int "same section keeps one fast profile" 1
            (List.length fast_profiles);
          check (list string) "invalid override preserves Codex argv append"
            [ "--profile"; "fast" ]
            fast_profile.argv_append;
          check bool "invalid override preserves exec mode override" true
            (match fast_profile.exec_mode_override with
            | Some Exec -> true
            | Some Spawn | Some Print | None -> false);
          check bool "same-section warning recorded" true
            (warnings
            |> List.exists
                 (contains_substring
                    ~needle:"profiles.claude.fast.argv_append"))))

let () =
  run "config loader profile identity"
    [
      ( "profiles",
        [
          test_case "same section override keeps extends-derived profile"
            `Quick
            test_profile_fallback_preserves_section_identity_with_extends;
        ] );
    ]
