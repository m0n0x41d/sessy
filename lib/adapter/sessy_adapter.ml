module type SOURCE = Source.SOURCE

module Claude = Claude
module Codex = Codex

let adapter_for_tool = function
  | Sessy_domain.Claude -> (module Claude : SOURCE)
  | Sessy_domain.Codex -> (module Codex : SOURCE)

let all_adapters = [ (module Claude : SOURCE); (module Codex : SOURCE) ]
