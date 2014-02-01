require 'neg'

class SexprParser < Neg::Parser
  parser do
    expr == list | atom
    spaces == _("\s\r\n") * 1
    list == `(` + (expr + (spaces + expr) * 0 ) * 0 + `)`
    atom == string | number | symbol
    string == `"` + (_('^"\\\\') + (`\\` + _) * -1) * 0 + `"`
    number == `-` * -1 + _('0-9') * 1
    symbol == (-spaces + _('^()')) * 1
  end

  translator do
    on(:expr) {|t| t.results.first}
    on(:spaces) { throw nil }
    on(:list) {|t| t.flattened_results}
    on(:atom) {|t| t.results.first}
    on(:string) {|t| t.result[1..-2].gsub(/[\\](.)/, '\1')}
    on(:number) {|t| t.result.to_i}
    on(:symbol) {|t| t.result.to_sym}
  end
end

if __FILE__ == $0
  require 'pp'

  p = SexprParser
  pp p.parse('-23')
  pp p.parse('"foo"')
  pp p.parse('foo')
  pp p.parse('(foo bar - 123 "zz\\"to\\\\p")')
end
