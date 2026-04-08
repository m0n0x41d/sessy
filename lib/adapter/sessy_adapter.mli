module type SOURCE = sig
  val tool : Sessy_domain.tool

  val parse_history :
    string -> (Sessy_domain.session list, Sessy_domain.parse_error) result

  val parse_detail :
    string -> (Sessy_domain.session, Sessy_domain.parse_error) result
end

module Claude : SOURCE
module Codex : SOURCE

val adapter_for_tool : Sessy_domain.tool -> (module SOURCE)
val all_adapters : (module SOURCE) list
