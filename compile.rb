require 'llvm/core'
require 'llvm/execution_engine'
require 'llvm/analysis'
require 'llvm/transforms/scalar'
require 'llvm/transforms/builder'


class Sym
  attr_accessor :name, :type, :storage, :value

  def initialize(name, type, storage, value)
    @name, @type, @storage, @value = name, type, storage, value
  end
end

class Scope
  def initialize(fun, parentscope)
    @fun = fun
    @parent = parentscope
    @tab = {}
  end

  def [](sym)
    # puts "#{self} in #@fun: looking up #{sym}, have #{@tab.keys.join(" ")}"
    @tab[sym] || @parent[sym]
  end

  def add(sym)
    @tab[sym.name] = sym
  end
end

class Function
  attr_reader :curblk, :mod

  def initialize(mod, name, argnames, parentscope)
    @mod = mod
    @name = name
    @argnames = argnames
    @parentscope = parentscope

    @mod.functions.add(@name, [LLVM::Int]*argnames.count, LLVM::Int) do |f, *argvals|
      @f = f
      @parentscope.add(Sym.new(name, nil, :const, @f))
      @syms = [Scope.new(name, @parentscope)]

      self.new_blk!
      argnames.zip(argvals) do |n, v|
        v.name = "__arg_#{n}"
        self.create_var(n, v)
      end
    end
  end

  def val
    @f
  end

  def syms
    @syms.last
  end

  def push_scope
    @syms.push Scope.new("XXX push", self.syms)
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
      self.syms.add(Sym.new(sym, nil, :stack, mem))
    end
    mem
  end

  def gen_body(body)
    val = nil
    body.each do |be|
      val = self.gen(be)
    end
    val
  end

  def gen_funcall(fun, args)
    evald_args = args.map{|e| gen(e)}
    self.build do |b|
      b.call(fun, *evald_args)
    end
  end

  def gen_invocation(expr)
    pred_sym, *args = expr
    pred = gen(pred_sym)

    if pred.is_a? LLVM::Value
      val = gen_funcall(pred, args)
    elsif pred.respond_to? :call
      val = pred.call(self, args)
    else
      raise RuntimeError, "invalid indentifier `#{pred_sym} (#{pred})'"
    end
  end

  def gen(expr)
    val = nil
    case expr
    when Numeric
      val = LLVM::Int(expr)
    when Array
      val = gen_invocation(expr)
    else
      val = self.syms[expr]
      case val.storage
      when :const, :builtin
        val = val.value
      when :stack
        self.build do |b|
          val = b.load(val.value)
        end
      else
        raise RuntimeError, "unknown value type"
      end
    end
    val
  end
end

class Compile
  module Builtins
    Ops_arith = {
      :+ => :add,
      :- => :sub,
      :* => :mul,
      :/ => :sdiv,
    }

    Ops_cmp = {
      '='.to_sym => :eq,
      :not= => :ne,
      :< => :slt,
      :> => :sgt,
      :<= => :sle,
      :>= => :sge
    }

    Handlers = Scope.new("builtins", nil)

    def self.add(sym, &blk)
      Handlers.add(Sym.new(sym, nil, :builtin, proc(&blk)))
    end

    Ops_arith.each do |sym, op|
      add(sym) do |fn, args|
        evald_args = args.map{|a| fn.gen(a)}
        fn.build do |b|
          evald_args.reduce do |a1, a2|
            b.send(op, a1, a2)
          end
        end
      end
    end

    Ops_cmp.each do |sym, cmp|
      add(sym) do |fn, args|
        evald_args = args.map{|a| fn.gen(a)}
        fn.build do |b|
          evald_args.each_cons(2).map do |a1, a2|
            b.icmp(cmp, args[0], args[1])
          end.reduce do |a1, a2|
            b.and(a1, a2)
          end
        end
      end
    end

    add(:defn) do |fn, args|
      name, argnames, *body = args

      fn = Function.new(fn.mod, name, argnames, fn.syms)
      val = fn.gen_body(body)
      fn.build do |b|
        b.ret(val)
      end

      fn.val
    end

    add(:cond) do |fn, args|
      val = nil

      outblk = fn.create_blk

      nextblk = fn.curblk
      phis = args.each_slice(2).map do |c, r|
        fn.set_blk!(nextblk)
        nextblk = fn.create_blk
        resblk = fn.create_blk

        fn.build do |b|
          cv = fn.gen(c)
          take = b.icmp(:ne, cv, LLVM::Int(0))
          b.cond(take, resblk, nextblk)
        end

        fn.set_blk!(resblk)
        resval = fn.gen(r)
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

    add(:let) do |fn, args|
      assignments, *body = args

      fn.push_scope do
        assignments.each_slice(2) do |sym, expr|
          if !sym.is_a? Symbol
            raise RuntimeError, "need symbol in left hand position, got `#{sym}'/#{sym.class} instead"
          end

          val = fn.gen(expr)
          fn.create_var(sym, val)
        end

        val = fn.gen_body(body)
        val
      end
    end

    add(:while) do |fn, args|
      test, *body = args

      inblk = fn.curblk
      testblk = fn.create_blk
      outblk = fn.create_blk

      fn.build do |b|
        b.br(testblk)
      end

      bodyblk = fn.new_blk!
      bodyval = fn.gen_body(body)
      fn.build do |b|
        b.br(testblk)
      end

      fn.set_blk!(testblk)
      val = nil
      fn.build do |b|
        val = b.phi(LLVM::Int, {inblk => LLVM::Int(0), bodyblk => bodyval})
        testval = fn.gen(test)
        cond = b.icmp(:ne, testval, LLVM::Int(0))
        b.cond(cond, bodyblk, outblk)
      end

      fn.set_blk!(outblk)
      val
    end

    add(:set!) do |fn, args|
      var_sym, val_sym = args

      var = fn.syms[var_sym]
      if not var || var.storage != :stack
        raise RuntimeError, "target `#{args[1]}' is not mutable"
      end
      val = fn.gen(val_sym)
      fn.build do |b|
        b.store(val, var.value)
      end
      val
    end
  end

  def initialize(mod)
    @m = LLVM::Module.new(mod)
    @globals = Scope.new("globals", Builtins::Handlers)
  end

  def run(modexpr)
    LLVM.init_jit

    mainfn = Function.new(@m, :main, [], @globals)
    val = mainfn.gen_body(modexpr)
    mainfn.build do |b|
      b.ret val
    end

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
