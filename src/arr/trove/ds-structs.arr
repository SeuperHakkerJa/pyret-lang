provide *
provide-types *

import global as _
include lists
include option
import sets as S
include string-dict
import srcloc as SL
import ast as AST

data Variable:
  | v-name(loc :: AST.Loc, name :: String)
  | v-atom(name :: String, serial :: Number)
end

data GenericPrimitive:
  | e-str(s :: String)
  | e-num(n :: Number)
  | e-bool(b :: Boolean)
  | e-loc(l :: AST.Loc)
end

data Term:
  | g-prim(val :: GenericPrimitive)
  | g-core(op :: String, args :: List<Term>)
  | g-surf(op :: String, args :: List<Term>, from-user :: Boolean)
  | g-aux(op :: String, args :: List<Term>)
  | g-var(v :: Variable)
  | g-list(lst :: List<Term>)
  | g-option(opt :: Option<Term>)
  | g-tag(lhs :: Pattern, rhs :: Pattern, body :: Term)
  | g-focus(t :: Term)
  | g-value(val :: Any)
end

data VarSign:
  | var-decl
  | var-refn
end

data Pattern:
  | p-pvar(name :: String, labels :: S.Set<String>, typ :: Option<String>)
  | p-drop(typ :: Option<String>)
  | p-prim(val :: GenericPrimitive)
  | p-core(op :: String, args :: List<Pattern>)
  | p-surf(op :: String, args :: List<Pattern>, from-user :: Boolean)
  | p-aux(op :: String, args :: List<Pattern>)
  | p-meta(op :: String, args :: List<Pattern>)
  | p-biject(op :: String, p :: Pattern)
  | p-var(name :: String)
  | p-list(l :: SeqPattern)
  | p-option(opt :: Option<Pattern>)
  | p-tag(lhs :: Pattern, rhs :: Pattern, body :: Pattern)
  | p-fresh(fresh :: List<FreshItem>, body :: Pattern)
  | p-capture(capture :: List<FreshItem>, body :: Pattern)
end

data SeqPattern:
  | seq-empty
  | seq-cons(first :: Pattern, rest :: SeqPattern)
  | seq-ellipsis(p :: Pattern, label :: String)
  | seq-ellipsis-list(patts :: List<Pattern>, label :: String)
end

data FreshItem:
  | fresh-name(name :: String)
  | fresh-ellipsis(item :: FreshItem, label :: String)
end

type DsRules = StringDict<List<DsRuleCase>>

data DsRuleCase:
  | ds-rule-case(lhs :: Pattern, rhs :: Pattern)
end

data ScopeRuleset:
  | scope-rule-set(map :: StringDict<ScopeRule>)
end

data ScopeRule:
  | scope-rule(
      exports :: List<Number>,         # i means export child i's declarations
      binds :: List<{Number; Number}>) # {i; j} means bind child j in child i
end

naked-var = v-name(AST.dummy-loc, _)

data Env:
  | environment(
      pvar-map :: StringDict<Term>,
      fresh-map :: StringDict<Variable>,
      ellipsis-map :: StringDict<List<Env>>)
end


################################################################################
#  Errors
#

fun panic(message :: String):
  raise({"Internal error when desugaring"; message})
end

fun fail(message :: String):
  raise({"Error when desugaring"; message})
end

fun fail-rs(message :: String):
  raise({"Error when resugaring"; message})
end


################################################################################
#  Metafunctions and Bijections
#

data Metafunction:
  | metafunction(arity :: Number, f :: (List<Term> -> Term))
end

__METAFUNCTIONS = [mutable-string-dict:]

fun add-metafunction(op :: String, arity :: Number, f :: (List<Term> -> Term)):
  __METAFUNCTIONS.set-now(op, metafunction(arity, f))
end

fun lookup-metafunction(op :: String) -> Metafunction:
  cases (Option) __METAFUNCTIONS.get-now(op):
    | none => fail("Metafunction '" + op + "' not found")
    | some(metaf) => metaf
  end
end

__BIJECTIONS = [mutable-string-dict:]

fun add-bijection(op :: String, forward :: (Term -> Term), rev :: (Term -> Term)):
  __BIJECTIONS.set-now(op, {forward; rev})
end

fun lookup-bijection(op :: String) -> { (Term -> Term); (Term -> Term) }:
  # Note: above spacing must be preserved to satisfy Elder Gods.
  cases (Option) __BIJECTIONS.get-now(op):
    | none => fail("Bijection '" + op + "' not found")
    | some(bij) => bij
  end
end


################################################################################
#  Utilities
#

fun get-fresh-item-name(item :: FreshItem) -> String:
  cases (FreshItem) item:
    | fresh-name(name) => name
    | fresh-ellipsis(shadow item, _) => get-fresh-item-name(item)
  end
end

fun rename-p-pvar(p :: Pattern, rename :: (String, S.Set<String>, Option<String> -> Pattern)) -> Pattern:
  fun loop(shadow p :: Pattern):
    cases (Pattern) p:
      | p-pvar(s, labels, t) => rename(s, labels, t)
      | p-drop(t) => p
      | p-prim(_) => p
      | p-core(op, args) => p-core(op, args.map(loop))
      | p-surf(op, args, from-user) => p-surf(op, args.map(loop), from-user)
      | p-aux(op, args) => p-aux(op, args.map(loop))
      | p-meta(op, args) => p-meta(op, args.map(loop))
      | p-biject(op, shadow p) => p-biject(op, loop(p))
      | p-var(_) => p
      | p-list(l) => p-list(loop-list(l))
      | p-option(opt) => p-option(opt.and-then(loop))
      | p-tag(lhs, rhs, body) => p-tag(loop(lhs), loop(rhs), loop(body))
      | p-fresh(fresh, body) => p-fresh(fresh, loop(body))
      | p-capture(capture, body) => p-capture(capture, loop(body))
    end
  end
  fun loop-list(ps :: SeqPattern):
    cases (SeqPattern) ps:
      | seq-empty => seq-empty
      | seq-cons(shadow p, shadow ps) => seq-cons(loop(p), loop-list(ps))
      | seq-ellipsis(shadow p, l) => seq-ellipsis(loop(p), l)
      | seq-ellipsis-list(lst, l) => seq-ellipsis-list(lst.map(loop), l)
    end
  end
  loop(p)
end

term-dummy-loc = g-prim(e-loc(AST.dummy-loc))

fun strip-tags(e :: Term) -> Term:
  cases (Term) e:
    | g-focus(p) => g-focus(strip-tags(p))
    | g-value(v) => g-value(v)
    | g-prim(val) => g-prim(val)
    | g-core(op, args) => g-core(op, args.map(strip-tags))
    | g-aux(op, args) => g-aux(op, args.map(strip-tags))
    | g-surf(op, args, from-user) => g-surf(op, args.map(strip-tags), from-user)
    | g-list(seq) => g-list(seq.map(strip-tags))
    | g-option(opt) => g-option(opt.and-then(strip-tags))
    | g-var(v) => g-var(v)
    | g-tag(_, _, body) => strip-tags(body)
  end
end

fun show-term(e :: Term) -> String:
  doc: "Print a term, for debugging purposes."
  fun show-prim(prim):
    cases (GenericPrimitive) prim:
      | e-str(v) => "\"" + tostring(v) + "\""
      | e-num(v) => tostring(v)
      | e-bool(v) => tostring(v)
      | e-loc(v) => "."
    end
  end
  fun show-var(v):
    cases (Variable) v:
      | v-name(_, name) => name
      | v-atom(name, _) => name
    end
  end
  cases (Term) e:
    | g-prim(val) => show-prim(val)
    | g-core(op, args) => "<" + op + " " + show-terms(args) + ">"
    | g-aux(op, args)  => "{" + op + " " + show-terms(args) + "}"
    | g-surf(op, args, from-user) => "(" + if from-user: "%" else: "" end + op + " " + show-terms(args) + ")"
    | g-list(lst)      => "[" + show-terms(lst) + "]"
    | g-focus(t) => "「" + show-term(t) + "」"
    | g-value(v) => tostring(v)
    | g-option(opt) =>
      cases (Option) opt:
        | none => "none"
        | some(shadow e) => "{some " + show-term(e) + "}"
      end
    | g-var(v) => show-var(v)
    | g-tag(_, _, body) => "#" + show-term(body)
  end
end

fun show-terms(es):
  map(show-term, es).join-str(" ")
end

fun free-pvars(p :: Pattern) -> S.Set<String>:
  fun loop(shadow p :: Pattern):
    cases (Pattern) p:
      | p-pvar(name, _, _) => [S.set: name]
      | p-drop(_) => S.empty-set
      | p-prim(_) => S.empty-set
      | p-core(_, args) => unions(map(loop, args))
      | p-surf(_, args, _) => unions(map(loop, args))
      | p-aux(_, args)  => unions(map(loop, args))
      | p-meta(_, args) => unions(map(loop, args))
      | p-biject(_, shadow p) => free-pvars(p)
      | p-var(_) => S.empty-set
      | p-option(opt) =>
        cases (Option) opt:
          | none => S.empty-set
          | some(shadow p) => free-pvars(p)
        end
      | p-tag(_, _, _) => panic("Unexpected tag encountered while collecting free pattern variables")
      | p-fresh(_, body) => free-pvars(body)
      | p-capture(_, body) => free-pvars(body)
      | p-list(l) => loop-list(l)
    end
  end
  fun loop-list(ps :: SeqPattern):
    cases (SeqPattern) ps:
      | seq-empty => S.empty-set
      | seq-cons(shadow p, shadow ps) => loop(p).union(loop-list(ps))
      | seq-ellipsis(shadow p, _) => loop(p)
      | seq-elipsis-list(lst) => unions(map(loop, lst))
    end
  end
  loop(p)
end

# This is an approximation; there are edge cases of ellipses where it fails.
fun dropped-pvars(rule-case :: DsRuleCase) -> S.Set<String>:
  free-pvars(rule-case.lhs).difference(free-pvars(rule-case.rhs))
end

fun unions(some-sets):
  for fold(answer from S.empty-set, a-set from some-sets):
    answer.union(a-set)
  end
end

fun rules-union(rules1 :: DsRules, rules2 :: DsRules) -> DsRules:
  for fold(rules from rules1, key from rules2.keys-list()):
    rules.set(key, rules2.get-value(key))
  end
end