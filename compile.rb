require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/analysis'
require 'llvm/transforms/scalar'
require 'llvm/transforms/builder'

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
    end,
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

  def cond(state, args)
    val = nil

    blk = state[:blk]
    outblk = blk.parent.basic_blocks.append

    nextblk = blk
    phis = args.each_slice(2).map do |c, r|
      thisblk = nextblk
      nextblk = thisblk.parent.basic_blocks.append
      resblk = thisblk.parent.basic_blocks.append

      thisblk.build do |b|
        state, cv = gen(state, c)
        take = b.icmp(:ne, cv, LLVM::Int(0))
        b.cond(take, resblk, nextblk)
      end

      resstate, resval = gen(state.merge({:blk => resblk}), r)
      resstate[:blk].build do |b|
        b.br outblk
      end
      [resstate[:blk], resval]
    end
    nextblk.build do |b|
      b.br outblk
    end
    phis << [nextblk, LLVM::Int(0)]

    outblk.build do |b|
      val = b.phi(LLVM::Int, Hash[*phis.flatten])
    end
    state = state.merge({:blk => outblk})

    [state, val]
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
      when :cond
        args = expr[1..-1]
        state, val = cond(state, args)
      else
        final = expr.map{|e| state, v = gen(state, e); v}
        pred = final.first
        args = final[1..-1]

        state[:blk].build do |b|
          if pred.respond_to? :call
            val = pred.call(b, args)
          else
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

    @m.dump

    jit = LLVM::JITCompiler.new(@m)
    passmgr = LLVM::FunctionPassManager.new(jit, @m)
    pb = LLVM::PassManagerBuilder.new
    pb.opt_level = 3
    pb.size_level = 2
    pb.build(passmgr)

    @m.functions.each do |f|
      passmgr.run(f)
    end

    passmgr.dispose
    pb.dispose

    @m.dump

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
