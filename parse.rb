require 'neg'

class SexprParser < Neg::Parser
  parser do
    expr == spaces? + (list | atom) + spaces?
    list == `(` + expr * 0 + `)`
    atom == string | number | symbol
    string == `"` + (_('^"\\\\') + (`\\` + _) * -1) * 0 + `"`
    number == `-` * -1 + _('0-9') * 1
    symbol == (-spaces + _('^()')) * 1

    spaces == _("\s\r\n") * 1
    spaces? == spaces * -1
  end

  translator do
    on(:expr) {|t| t.results.first.first}
    on(:list) {|t| t.results.first}
    on(:atom) {|t| t.results.first}
    on(:string) {|t| t.result[1..-2].gsub(/[\\](.)/, '\1')}
    on(:number) {|t| t.result.to_i}
    on(:symbol) {|t| t.result.to_sym}

    on(:spaces) { throw nil }
    on(:spaces?) { throw nil }
  end
end

if __FILE__ == $0
  require 'pp'

  p = SexprParser
  pp p.parse('-23')
  pp p.parse('"foo"')
  pp p.parse('foo')
  pp p.parse('((foo))')
  pp p.parse('()')
  pp p.parse('(())')
  pp p.parse('(foo bar - 123 "zz\\"to\\\\p")')
end
