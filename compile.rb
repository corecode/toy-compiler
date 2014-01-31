require 'llvm/core'
require 'llvm/execution_engine'

class Compile
  BUILTINS = {
    :+ => proc do |b, args|
      args.reduce do |a1, a2|
        b.add(a1, a2)
      end
    end,
    :- => proc do |b, args|
      args.reduce do |a1, a2|
        b.sub(a1, a2)
      end
    end,
    :* => proc do |b, args|
      args.reduce do |a1, a2|
        b.mul(a1, a2)
      end
    end,
    :/ => proc do |b, args|
      args.reduce do |a1, a2|
        b.sdiv(a1, a2)
      end
    end
  }

  def initialize(mod)
    @m = LLVM::Module.new(mod)
  end

  def gen(b, expr)
    case expr
    when Numeric
      LLVM::Int(expr)
    when Array
      final = expr.map{|e| gen(b, e)}
      pred = final.first
      args = final[1..-1]
      if BUILTINS.include? pred
        BUILTINS[pred].call(b, args)
      end
    else
      expr
    end
  end

  def run(expr)
    LLVM.init_jit

    @m.functions.add("testfn", [], LLVM::Int) do |f, n|
      f.basic_blocks.append("b").build do |b|
        b.ret(gen(b, expr))
        #v = b.add(LLVM::Int(10), LLVM::Int(2))
        #b.ret(v)
      end
    end

    #@m.verify
    @m.dump

    jit = LLVM::JITCompiler.new(@m)
    jit.run_function(@m.functions["testfn"]).to_i
  end
end

if $0 == __FILE__
  $: << File.expand_path("..", __FILE__)
  require 'parse'
  require 'pp'

  c = Compile.new("test")
  p = SexprParser.parse(ARGV.join)
  pp c.run(p)
end
