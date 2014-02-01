require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/analysis'
require 'llvm/transforms/scalar'
require 'llvm/transforms/builder'

class Compile
  module Builtins
    Handlers = {}

    {
      :+ => :add,
      :- => :sub,
      :* => :mul,
      :/ => :sdiv,
    }.each do |sym, op|
      Handlers[sym] = proc do |b, args|
        args.reduce do |a1, a2|
          b.send(op, a1, a2)
        end
      end
    end

    {
      '='.to_sym => :eq,
      :not= => :ne,
      :< => :slt,
      :> => :sgt,
      :<= => :sle,
      :>= => :sge
    }.each do |sym, cmp|
      Handlers[sym] = proc do |b, args|
        args.each_cons(2).map do |a1, a2|
          b.icmp(cmp, args[0], args[1])
        end.reduce do |a1, a2|
          b.and(a1, a2)
        end
      end
    end

    def self.include?(sym)
      Handlers.include? sym
    end

    def self.gen(sym, b, args)
      Handlers[sym].call(b, args)
    end
  end

  def initialize(mod)
    @m = LLVM::Module.new(mod)
    @symbols = {}
  end

  def defn(name, argnames, body)
    @m.functions.add(name, [LLVM::Int]*argnames.count, LLVM::Int) do |f, *argvals|
      @symbols[name] = {:type => :const, :val => f}

      state = {}
      state[:blk] = f.basic_blocks.append

      state[:blk].build do |b|
        state[:sym] = sym = {}
        argnames.zip(argvals) do |n, v|
          v.name = "__arg_#{n}"
          memv = b.alloca(v.type)
          memv.name = "#{n}"
          b.store(v, memv)
          sym[n] = {:type => :loc, :val => memv}
        end
      end

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
      when :set!
        sym = expr[1]
        sym = state[:sym][sym]
        if not sym || sym[:val] != :loc
          raise RuntimeError, "target `#{args[1]}' is not mutable"
        end
        state, val = gen(state, expr[2])
        state[:blk].build do |b|
          b.store(val, sym[:val])
        end
      else
        final = expr.map{|e| state, v = gen(state, e); v}
        pred = expr.first
        fun = final.first
        args = final[1..-1]

        state[:blk].build do |b|
          if fun.is_a? LLVM::Value
            val = b.call(fun, *args)
          elsif Builtins.include? pred
            val = Builtins.gen(pred, b, args)
          else
            raise RuntimeError, "invalid indentifier `#{pred}' (#{fun})"
          end
        end
      end
    else
      val = state[:sym][expr] || @symbols[expr]
      if val
        case val[:type]
        when :const
          val = val[:val]
        when :loc
          state[:blk].build do |b|
            val = b.load(val[:val])
          end
        else
          raise RuntimeError, "unknown value type"
        end
      end
    end
    [state, val]
  end

  def run(mainexpr)
    LLVM.init_jit

    defn(:main, [], mainexpr)

    $stderr.puts "#### unoptimized:"
    @m.dump

    jit = LLVM::JITCompiler.new(@m)
    passmgr = LLVM::FunctionPassManager.new(jit, @m)
    pb = LLVM::PassManagerBuilder.new
    pb.opt_level = 3
    pb.size_level = 2
    pb.build(passmgr)
    passmgr.tailcallelim!

    @m.functions.each do |f|
      passmgr.run(f)
    end

    passmgr.dispose
    pb.dispose

    $stderr.puts "\n\n#### optimized:"
    @m.dump

    jit.run_function(@m.functions["main"]).to_i
  end
end

if $0 == __FILE__
  $: << File.expand_path("..", __FILE__)
  require 'parse'
  require 'pp'

  c = Compile.new("test")
  p = SexprParser.parse('('+ARGV.join.strip+')')
  res = c.run(p)
  puts "\n#### result:"
  pp res
end
