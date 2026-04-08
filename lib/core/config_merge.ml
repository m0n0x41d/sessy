open Sessy_domain

let default_sources =
  [
    {
      tool = Claude;
      history_path = "~/.claude/history.jsonl";
      projects_path = Some "~/.claude/projects";
      sessions_path = Some "~/.claude/sessions";
    };
    {
      tool = Codex;
      history_path = "~/.codex/history.jsonl";
      projects_path = None;
      sessions_path = Some "~/.codex/sessions";
    };
  ]

let default_launches =
  [
    ( Claude,
      {
        argv_template = [ "claude"; "--resume"; "{{id}}" ];
        cwd_policy = `Session;
        default_exec_mode = Spawn;
      } );
    ( Codex,
      {
        argv_template = [ "codex"; "resume"; "{{id}}" ];
        cwd_policy = `Session;
        default_exec_mode = Spawn;
      } );
  ]

let default_config =
  {
    default_scope = Repo;
    preview = true;
    sources = default_sources;
    launches = default_launches;
    profiles = [];
  }

let merge_list base override = match override with [] -> base | _ -> override

let merge_config base override =
  {
    default_scope = override.default_scope;
    preview = override.preview;
    sources = merge_list base.sources override.sources;
    launches = merge_list base.launches override.launches;
    profiles = merge_list base.profiles override.profiles;
  }

let resolve_config layers = layers |> List.fold_left merge_config default_config
