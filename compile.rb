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
    @symbols = BUILTINS.dup
  end

  def defn(name, argnames, body)
    @m.functions.add(name, [LLVM::Int]*argnames.count, LLVM::Int) do |f, *argvals|
      @symbols[name] = f

      argsyms = argnames.zip(argvals).map do |n, v|
        v.name = n.to_s
        [n, v]
      end
      argsyms = Hash[*argsyms.flatten]
      state = {:sym => argsyms}
      state[:blk] = f.basic_blocks.append

      v = nil
      body.each do |bodyexpr|
        state, v = gen(state, bodyexpr)
      end

      state[:blk].build do |b|
        b.ret(v)
      end
    end
  end

  def gen(state, expr)
    val = nil
    case expr
    when Numeric
      val = LLVM::Int(expr)
    when Array
      case expr.first
      when :defn
        name = expr[1]
        args = expr[2]
        body = expr[3..-1]
        val = defn(name, args, body)
      else
        final = expr.map{|e| state, v = gen(state, e); v}
        pred = final.first
        args = final[1..-1]

        state[:blk].build do |b|
          begin
            val = pred.call(b, args)
          rescue
            val = b.call(pred, *args)
          end
        end
      end
    else
      val = state[:sym][expr] || @symbols[expr]
    end
    [state, val]
  end

  def run(mainexpr)
    LLVM.init_jit

    defn(:main, [], mainexpr)
    # @m.functions.add("main", [], LLVM::Int) do |f, n|
    #   b, val = mainexpr.map do |e|
    #     f.basic_blocks.append.build do |b|
    #       pp e
    #       [b, gen(b, @syms, e)]
    #     end
    #   end
    #   b.ret(val)
    # end

    @m.dump

    jit = LLVM::JITCompiler.new(@m)
    jit.run_function(@m.functions["main"]).to_i
  end
end

if $0 == __FILE__
  $: << File.expand_path("..", __FILE__)
  require 'parse'
  require 'pp'

  c = Compile.new("test")
  p = SexprParser.parse('('+ARGV.join+')')
  pp c.run(p)
end
