module type SOURCE = sig
  val tool : Sessy_domain.tool

  val parse_history :
    string -> (Sessy_domain.session list, Sessy_domain.parse_error) result

  val parse_detail :
    string -> (Sessy_domain.session, Sessy_domain.parse_error) result
end
