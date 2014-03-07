require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/analysis'
require 'llvm/transforms/scalar'
require 'llvm/transforms/builder'

class Scope
  def initialize(fun, parentscope)
    @fun = fun
    @parent = parentscope
    @tab = {}
  end

  def [](sym)
    puts "#{self}: looking up #{sym}"
    @tab[sym] || @parent[sym]
  end

  def []=(sym, val)
    @tab[sym] = val
  end
end

class Function
  attr_reader :curblk

  def initialize(mod, name, argnames, parentscope)
    @mod = mod
    @name = name
    @argnames = argnames
    @parentscope = parentscope

    @mod.functions.add(@name, [LLVM::Int]*argnames.count, LLVM::Int) do |f, *argvals|
      @f = f
      @parentscope[name] = {:type => :const, :val => @f}
      @syms = [Scope.new(self, @parentscope)]

      self.new_blk!
      argnames.zip(argvals) do |n, v|
        v.name = "__arg_#{n}"
        self.create_var(n, v)
      end
    end
  end

  def syms
    @syms.last
  end

  def push_scope
    @syms.push Scope.new(self, self.syms)
    if block_given?
      begin
        yield
      ensure
        self.pop_scope
      end
    end
  end

  def pop_scope
    @syms.pop
  end

  def new_blk!
    self.set_blk!(self.create_blk)
  end

  def set_blk!(blk)
    @curblk = blk
  end

  def create_blk
    @f.basic_blocks.append
  end

  def build(&p)
    val = nil
    @curblk.build do |b|
      val = yield b
    end
    val
  end

  def create_var(sym, init_val)
    mem = nil
    self.build do |b|
      mem = b.alloca(init_val.type)
      mem.name = "#{sym}"
      b.store(init_val, mem)
      self.syms[sym] = {:type => :loc, :val => mem}
    end
    mem
  end
end

class Compile
  module Builtins
    Handlers = Scope.new(nil, nil)

    {
      :+ => :add,
      :- => :sub,
      :* => :mul,
      :/ => :sdiv,
    }.each do |sym, op|
      h = proc do |fn, args|
        fn.build do |b|
          args.reduce do |a1, a2|
            b.send(op, a1, a2)
          end
        end
      end
      Handlers[sym] = {:type => :const, :val => h}
    end

    {
      '='.to_sym => :eq,
      :not= => :ne,
      :< => :slt,
      :> => :sgt,
      :<= => :sle,
      :>= => :sge
    }.each do |sym, cmp|
      h = proc do |fn, args|
        fn.build do |b|
          args.each_cons(2).map do |a1, a2|
            b.icmp(cmp, args[0], args[1])
          end.reduce do |a1, a2|
            b.and(a1, a2)
          end
        end
      end
      Handlers[sym] = {:type => :const, :val => h}
    end
  end

  def initialize(mod)
    @m = LLVM::Module.new(mod)
    @globals = Scope.new(nil, Builtins::Handlers)
  end

  def defn(name, argnames, body)
    fn = Function.new(@m, name, argnames, @globals)

    val = gen_body(fn, body)
    fn.build do |b|
      b.ret(val)
    end
  end

  def cond(fn, args)
    val = nil

    outblk = fn.create_blk

    nextblk = fn.curblk
    phis = args.each_slice(2).map do |c, r|
      fn.set_blk!(nextblk)
      nextblk = fn.create_blk
      resblk = fn.create_blk

      fn.build do |b|
        cv = gen(fn, c)
        take = b.icmp(:ne, cv, LLVM::Int(0))
        b.cond(take, resblk, nextblk)
      end

      fn.set_blk!(resblk)
      resval = gen(fn, r)
      fn.build do |b|
        b.br outblk
      end
      resval
    end

    fn.set_blk!(nextblk)
    fn.build do |b|
      b.br outblk
    end
    phis << [nextblk, LLVM::Int(0)]

    fn.set_blk!(outblk)
    fn.build do |b|
      val = b.phi(LLVM::Int, Hash[*phis.flatten])
    end

    fn.set_blk!(outblk)
    val
  end

  def let(fn, assignments, body)
    fn.push_scope do
      assignments.each_slice(2) do |sym, expr|
        if !sym.is_a? Symbol
          raise RuntimeError, "need symbol in left hand position, got `#{sym}'/#{sym.class} instead"
        end

        val = gen(fn, expr)
        fn.create_var(sym, val)
      end

      val = gen_body(fn, body)
      val
    end
  end

  def loop_while(fn, test, body)
    inblk = fn.curblk
    testblk = fn.create_blk
    outblk = fn.create_blk

    fn.build do |b|
      b.br(testblk)
    end

    bodyblk = fn.new_blk!
    bodyval = gen_body(fn, body)
    fn.build do |b|
      b.br(testblk)
    end

    fn.set_blk!(testblk)
    val = nil
    fn.build do |b|
      val = b.phi(LLVM::Int, {inblk => LLVM::Int(0), bodyblk => bodyval})
      testval = gen(fn, test)
      cond = b.icmp(:ne, testval, LLVM::Int(0))
      b.cond(cond, bodyblk, outblk)
    end

    fn.set_blk!(outblk)
    val
  end

  def gen(fn, expr)
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
        sym = fn.syms[sym]
        if not sym || sym[:val] != :loc
          raise RuntimeError, "target `#{args[1]}' is not mutable"
        end
        val = gen(fn, expr[2])
        fn.build do |b|
          b.store(val, sym[:val])
        end
      when :let
        assignments = expr[1]
        body = expr[2..-1]
        val = let(fn, assignments, body)
      when :while
        test = expr[1]
        body = expr[2..-1]
        val = loop_while(fn, test, body)
      else
        final = expr.map{|e| v = gen(fn, e); v}
        pred = expr.first
        fun = final.first
        args = final[1..-1]

        fn.build do |b|
          if fun.is_a? LLVM::Value
            val = b.call(fun, *args)
          elsif fun.respond_to? :call
            val = fun.call(fn, args)
          else
            raise RuntimeError, "invalid indentifier `#{pred}' (#{fun})"
          end
        end
      end
    else
      val = fn.syms[expr]
      if val
        case val[:type]
        when :const
          val = val[:val]
        when :loc
          fn.build do |b|
            val = b.load(val[:val])
          end
        else
          raise RuntimeError, "unknown value type"
        end
      end
    end
    val
  end

  def gen_body(fn, body)
    val = nil
    body.each do |be|
      val = gen(fn, be)
    end
    val
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
