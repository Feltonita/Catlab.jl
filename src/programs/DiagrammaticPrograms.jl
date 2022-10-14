""" DSLs for defining categories, diagrams, and related structures.

Here "diagram" means diagram in the standard category-theoretic sense, not
string diagram or wiring diagram. DSLs for constructing wiring diagrams are
provided by other submodules.
"""
module DiagrammaticPrograms
export @graph, @fincat, @finfunctor, @diagram, @free_diagram,
  @migrate, @migration

using Base.Iterators: repeated
using MLStyle: @match

using ...GAT, ...Present, ...Graphs, ...CategoricalAlgebra
using ...Theories: munit
using ...CategoricalAlgebra.FinCats: mapvals, make_map
using ...CategoricalAlgebra.DataMigrations: ConjQuery, GlueQuery, GlucQuery
import ...CategoricalAlgebra.FinCats: FinCat, vertex_name, vertex_named,
  edge_name, edge_named

# Abstract syntax
#################

""" Abstract syntax trees for category and diagram DSLs.
"""
module AST

using MLStyle: @data
using StructEquality

@data HomExpr begin
  HomGenerator(name)
  Compose(homs::Vector{<:HomExpr})
  Id(ob)
end

@data DisplayedCatExpr begin
  ObOver(name::Symbol, over::Union{Symbol,Nothing})
  HomOver(name::Union{Symbol,Nothing}, src::Symbol, tgt::Symbol, over::HomExpr)
end

@data CatExpr <: DisplayedCatExpr begin
  Ob(name::Symbol)
  Hom(name::Union{Symbol,Nothing}, src::Symbol, tgt::Symbol)
  HomEq(lhs::HomExpr, rhs::HomExpr)
end

@data MappingExpr begin
  MapsTo(lhs, rhs)
end

@struct_equal struct Cat
  statements::Vector{CatExpr}
end
@struct_equal struct DisplayedCat
  statements::Vector{DisplayedCatExpr}
end
@struct_equal struct Mapping
  statements::Vector{MappingExpr}
end

end # AST module

""" Parse category or displayed category from Julia expression to AST.
"""
function parse_category_ast(body::Expr; free::Bool=false, preprocess::Bool=true)
  nanon = 0
  if preprocess
    body = reparse_arrows(body)
  end
  stmts = mapreduce(vcat, statements(body), init=AST.CatExpr[]) do stmt
    @match stmt begin
      # X
      X::Symbol => [AST.Ob(X)]
      # X, Y, ...
      Expr(:tuple, Xs...) => map(AST.Ob, Xs)
      # X → Y
      Expr(:call, :(→), X::Symbol, Y::Symbol) => [AST.Hom(nothing, X, Y)]
      # f : X → Y
      Expr(:call, :(:), f::Symbol, Expr(:call, :(→), X::Symbol, Y::Symbol)) =>
        [AST.Hom(f, X, Y)]
      # (f, g, ...) : X → Y
      Expr(:call, (:), Expr(:tuple, fs...),
           Expr(:call, :(→), X::Symbol, Y::Symbol)) =>
        map(f -> AST.Hom(f, X, Y), fs)
      # x => X
      # x::X
      Expr(:call, :(=>), x::Symbol, X) || Expr(:(::), x::Symbol, X) =>
        [AST.ObOver(x, X)]
      # (x, y, ...) => X
      # (x, y, ...)::X
      Expr(:call, :(=>), Expr(:tuple, xs...), X) ||
      Expr(:(::), Expr(:tuple, xs...), X) =>
        map(x -> AST.ObOver(x, X), xs)
      # (f: x → y) => h
      # (f: x → y)::h
      Expr(:call, :(=>), Expr(:call, :(:), f::Symbol,
                              Expr(:call, :(→), x::Symbol, y::Symbol)), h) ||
      Expr(:(::), Expr(:call, :(:), f::Symbol,
                       Expr(:call, :(→), x::Symbol, y::Symbol)), h) =>
        [AST.HomOver(f, x, y, parse_hom_ast(h))]
      # (x → y) => h
      # (x → y)::h
      Expr(:call, :(=>), Expr(:call, :(→), x::Symbol, y::Symbol), h) ||
      Expr(:(::), Expr(:call, :(→), x::Symbol, y::Symbol), h) =>
        [AST.HomOver(nothing, x, y, parse_hom_ast(h))]
      # h(x) == y
      # y == h(x)
      (Expr(:call, :(==), call::Expr, y::Symbol) ||
       Expr(:call, :(==), y::Symbol, call::Expr)) && if free end => begin
         h, x = destructure_unary_call(call)
         [AST.HomOver(nothing, x, y, parse_hom_ast(h))]
      end
      # h(x) == k(y)
      Expr(:call, :(==), lhs::Expr, rhs::Expr) && if free end => begin
        (h, x), (k, y) = destructure_unary_call(lhs), destructure_unary_call(rhs)
        z = Symbol("##unnamed#$(nanon += 1)")
        [AST.ObOver(z, nothing), AST.HomOver(nothing, x, z, parse_hom_ast(h)),
         AST.HomOver(nothing, y, z, parse_hom_ast(k))]
      end
      # f == g
      Expr(:call, :(==), lhs, rhs) && if !free end =>
        [AST.HomEq(parse_hom_ast(lhs), parse_hom_ast(rhs))]
      ::LineNumberNode => AST.CatExpr[]
      _ => error("Cannot parse statement in category definition: $stmt")
    end
  end
  (all(x -> x isa AST.CatExpr, stmts) ? AST.Cat : AST.DisplayedCat)(stmts)
end

""" Parse morphism expression from Julia expression to AST.
"""
function parse_hom_ast(expr)::AST.HomExpr
  @match expr begin
    Expr(:call, :compose, args...) => AST.Compose(map(parse_hom_ast, args))
    Expr(:call, :(⋅), f, g) || Expr(:call, :(⨟), f, g) =>
      AST.Compose([parse_hom_ast(f), parse_hom_ast(g)])
    Expr(:call, :(∘), f, g) => AST.Compose([parse_hom_ast(g), parse_hom_ast(f)])
    Expr(:call, :id, x) => AST.Id(x)
    f::Symbol || Expr(:curly, _...) => AST.HomGenerator(expr)
    _ => error("Invalid morphism expression $expr")
  end
end

function parse_mapping_ast(body)
  stmts = mapreduce(vcat, statements(body), init=AST.Mapping[]) do stmt
    @match stmt begin
      # x => y
      Expr(:call, :(=>), x::Symbol, rhs) => [AST.MapsTo(x, rhs)]
      # (x, x′, ...) => y
      Expr(:call, :(=>), Expr(:tuple, xs...), rhs) =>
        map(x -> AST.MapsTo(x, rhs), xs)
      ::LineNumberNode => AST.Mapping[]
      _ => error("Cannot parse statement in mapping definition: $stmt")
    end
  end
  AST.Mapping(stmts)
end

statements(expr) = (expr isa Expr && expr.head == :block) ? expr.args : [expr]

""" Reparse Julia expressions for function/arrow types.

In Julia, `f : x → y` is parsed as `(f : x) → y` instead of `f : (x → y)`.
"""
function reparse_arrows(expr)
  @match expr begin
    Expr(:call, :(→), Expr(:call, :(:), f, x), y) =>
      Expr(:call, :(:), f, Expr(:call, :(→), x, y))
    Expr(head, args...) => Expr(head, (reparse_arrows(arg) for arg in args)...)
    _ => expr
  end
end

""" Destructure Julia expression `:(f(g(x)))` to `(:(f∘g), :x)`, for example.
"""
function destructure_unary_call(expr::Expr)
  @match expr begin
    Expr(:call, head, x::Symbol) => (head, x)
    Expr(:call, head, arg) => begin
      rest, x = destructure_unary_call(arg)
      (Expr(:call, :(∘), head, rest), x)
    end
  end
end

# Graphs
########

@present SchNamedGraph <: SchGraph begin
  VName::AttrType
  EName::AttrType
  vname::Attr(V, VName)
  ename::Attr(E, EName)
end

""" Abstract type for graph with named vertices and edges.
"""
@abstract_acset_type AbstractNamedGraph <: AbstractGraph

""" Graph with named vertices and edges.

The default graph type used by [`@graph`](@ref), [`@fincat`](@ref),
[`@diagram`](@ref), and related macros.
"""
@acset_type NamedGraph(SchNamedGraph, index=[:src,:tgt,:ename],
                       unique_index=[:vname]) <: AbstractNamedGraph
# FIXME: The edge name should also be uniquely indexed, but this currently
# doesn't play nicely with nullable attributes.

vertex_name(g::AbstractNamedGraph, args...) = subpart(g, args..., :vname)
edge_name(g::AbstractNamedGraph, args...) = subpart(g, args..., :ename)

vertex_named(g::AbstractNamedGraph, name) = only(incident(g, name, :vname))
edge_named(g::AbstractNamedGraph, name)= only(incident(g, name, :ename))

""" Construct a graph in a simple, declarative style.

The syntax is reminiscent of Graphviz. Each line a declares a vertex or set of
vertices, or an edge. For example, the following defines a directed triangle:

```julia
@graph begin
  v0, v1, v2
  fst: v0 → v1
  snd: v1 → v2
  comp: v0 → v2
end
```

Vertices in the graph must be uniquely named, whereas edges names are optional.
"""
macro graph(graph_type, body)
  stmts = parse_category_ast(body)
  :(parse_graph($(esc(graph_type)), $stmts))
end
macro graph(body)
  stmts = parse_category_ast(body)
  :(parse_graph(NamedGraph{Symbol,Union{Symbol,Nothing}}, $stmts))
end

function parse_graph(::Type{G}, ast::AST.Cat) where
    {G <: HasGraph}
  g = G()
  foreach(stmt -> parse!(g, stmt), ast.statements)
  return g
end

parse!(g::HasGraph, ob::AST.Ob) = add_vertex!(g, vname=ob.name)

function parse!(g::HasGraph, hom::AST.Hom)
  e = add_edge!(g, vertex_named(g, hom.src), vertex_named(g, hom.tgt))
  if has_subpart(g, :ename)
    g[e,:ename] = hom.name
  end
  return e
end

# Categories
############

struct FinCatData{G<:HasGraph}
  graph::G
  equations::Vector{Pair}
end

FinCat(C::FinCatData) = isempty(C.equations) ? FinCat(C.graph) :
  FinCat(C.graph, C.equations)

""" Present a category by generators and relations.

The result is a finitely presented category (`FinCat`) represented by a graph,
possibly with path equations. For example, the simplex category truncated to one
dimension is:

```julia
@fincat begin
  V, E
  (δ₀, δ₁): V → E
  σ₀: E → V

  σ₀ ∘ δ₀ == id(V)
  σ₀ ∘ δ₁ == id(V)
end
```

The objects and morphisms must be uniquely named.
"""
macro fincat(body)
  stmts = parse_category_ast(body)
  :(parse_category(NamedGraph{Symbol,Symbol}, $stmts))
end

function parse_category(::Type{G}, ast::AST.Cat) where
    {G <: HasGraph}
  cat = FinCatData(G(), Pair[])
  foreach(stmt -> parse!(cat, stmt), ast.statements)
  FinCat(cat)
end

parse!(C::FinCatData, stmt) = parse!(C.graph, stmt)
parse!(C::FinCatData, eq::AST.HomEq) =
  push!(C.equations, parse_path(C.graph, eq.lhs) => parse_path(C.graph, eq.rhs))

function parse_path(g::HasGraph, expr::AST.HomExpr)
  @match expr begin
    AST.HomGenerator(f::Symbol) => Path(g, edge_named(g, f))
    AST.Compose(args) => mapreduce(arg -> parse_path(g, arg), vcat, args)
    AST.Id(x::Symbol) => empty(Path, g, vertex_named(g, x))
  end
end

# Functors
##########

""" Define a functor between two finitely presented categories.

Such a functor is defined by sending the object and morphism generators of the
domain category to generic object and morphism expressions in the codomain
category. For example, the following functor embeds the schema for graphs into
the schema for circular port graphs by ignoring the ports:

```julia
@finfunctor SchGraph SchCPortGraph begin
  V => Box
  E => Wire
  src => src ⨟ box
  tgt => tgt ⨟ box
end
```
"""
macro finfunctor(dom_cat, codom_cat, body)
  stmts = parse_mapping_ast(body)
  :(parse_functor($(esc(dom_cat)), $(esc(codom_cat)), $stmts))
end

function parse_functor(C::FinCat, D::FinCat, stmts)
  ob_rhs, hom_rhs = parse_ob_hom_maps(C, stmts)
  F = FinFunctor(mapvals(x -> parse_ob(D, x), ob_rhs),
                 mapvals(f -> parse_hom(D, parse_hom_ast(f)), hom_rhs), C, D)
  is_functorial(F, check_equations=false) ||
    error("Parsed functor is not functorial: $stmts")
  return F
end
function parse_functor(C::Presentation, D::Presentation, stmts; kw...)
  parse_functor(FinCat(C), FinCat(D), stmts; kw...)
end

function parse_ob_hom_maps(C::FinCat, ast::AST.Mapping;
                           missing_ob::Bool=false, missing_hom::Bool=false)
  assignments = Dict{Symbol,Union{Expr,Symbol}}()
  for (stmt::AST.MapsTo) in ast.statements
    lhs, rhs = stmt.lhs, stmt.rhs
    haskey(assignments, lhs) && error("Left-hand side $lhs assigned twice")
    assignments[lhs] = rhs
  end
  ob_rhs = make_map(ob_generators(C)) do x
    y = pop!(assignments, ob_generator_name(C, x), missing)
    (!ismissing(y) || missing_ob) ? y :
      error("Object $(ob_generator_name(C,x)) is not assigned")
  end
  hom_rhs = make_map(hom_generators(C)) do f
    g = pop!(assignments, hom_generator_name(C, f), missing)
    (!ismissing(g) || missing_hom) ? g :
      error("Morphism $(hom_generator_name(C,f)) is not assigned")
  end
  isempty(assignments) ||
    error(string("Unused assignment(s): ", join(keys(assignments), ", ")))
  (ob_rhs, hom_rhs)
end

""" Parse expression for object in a category.
"""
function parse_ob(C::FinCat{Ob,Hom}, expr) where {Ob,Hom}
  @match expr begin
    x::Symbol => ob_generator(C, x)
    Expr(:curly, _...) => parse_gat_expr(C, expr)::Ob
    _ => error("Invalid object expression $expr")
  end
end

""" Parse expression for morphism in a category.
"""
function parse_hom(C::FinCat{Ob,Hom}, expr::AST.HomExpr) where {Ob,Hom}
  @match expr begin
    AST.HomGenerator(fexpr) => @match fexpr begin
      f::Symbol => hom_generator(C, f)
      Expr(:curly, _...) => parse_gat_expr(C, fexpr)::Hom
      _ => error("Invalid morphism expression $expr")
    end
    AST.Compose(args) => mapreduce(
      arg -> parse_hom(C, arg), (fs...) -> compose(C, fs...), args)
    AST.Id(x) => id(C, parse_ob(C, x))
  end
end

""" Parse GAT expression based on curly braces, rather than parentheses.
"""
function parse_gat_expr(C::FinCat, root_expr)
  pres = presentation(C)
  function parse(expr)
    @match expr begin
      Expr(:curly, head::Symbol, args...) =>
        invoke_term(pres.syntax, head, map(parse, args)...)
      x::Symbol => generator(pres, x)
      _ => error("Invalid GAT expression $root_expr")
    end
  end
  parse(root_expr)
end

# Diagrams
##########

""" Present a diagram in a given category.

Recall that a *diagram* in a category ``C`` is a functor ``F: J → C`` from a
small category ``J`` into ``C``. Given the category ``C``, this macro presents a
diagram in ``C``, i.e., constructs a finitely presented indexing category ``J``
together with a functor ``F: J → C``. This method of simultaneous definition is
often more convenient than defining ``J`` and ``F`` separately, as could be
accomplished by calling [`@fincat`](@ref) and then [`@finfunctor`](@ref).

As an example, the limit of the following diagram consists of the paths of
length two in a graph:

```julia
@diagram SchGraph begin
  v::V
  (e₁, e₂)::E
  (t: e₁ → v)::tgt
  (s: e₂ → v)::src
end
```

Morphisms in the indexing category can be left unnamed, which is convenient for
defining free diagrams (see also [`@free_diagram`](@ref)). For example, the
following diagram is isomorphic to the previous one:

```julia
@diagram SchGraph begin
  v::V
  (e₁, e₂)::E
  (e₁ → v)::tgt
  (e₂ → v)::src
end
```

Of course, unnamed morphisms cannot be referenced by name within the `@diagram`
call or in other settings, which can sometimes be problematic.
"""
macro diagram(cat, body)
  :(parse_diagram($(esc(cat)), $(Meta.quot(body))))
end

""" Present a free diagram in a given category.

Recall that a *free diagram* in a category ``C`` is a functor ``F: J → C`` where
``J`` is a free category on a graph, here assumed finite. This macro is
functionally a special case of [`@diagram`](@ref) but, for convenience, changes
the interpretation of equality expressions. Rather than interpreting them as
equations between morphisms in ``J``, equality expresions can be used to
introduce anonymous morphisms in a "pointful" style. For example, the limit of
the following diagram consists of the paths of length two in a graph:

```julia
@free_diagram SchGraph begin
  v::V
  (e₁, e₂)::E
  tgt(e₁) == v
  src(e₂) == v
end
```

Anonymous objects can also be introduced. For example, the previous diagram is
isomorphic to this one:

```julia
@free_diagram SchGraph begin
  (e₁, e₂)::E
  tgt(e₁) == src(e₂)
end
```

Some care must exercised when defining morphisms between diagrams with anonymous
objects, since they cannot be referred to by name.
"""
macro free_diagram(cat, body)
  :(parse_diagram($(esc(cat)), $(Meta.quot(body)), free=true))
end

function parse_diagram(C::FinCat, body::Expr; kw...)
  F_ob, F_hom, J = parse_diagram_data(
    C, x -> parse_ob(C,x), (f,x,y) -> parse_hom(C,f), body; kw...)
  F = FinFunctor(F_ob, F_hom, J, C)
  is_functorial(F, check_equations=false) ||
    error("Parsed diagram is not functorial: $body")
  return F
end
parse_diagram(pres::Presentation, body::Expr; kw...) =
  parse_diagram(FinCat(pres), body; kw...)

function parse_diagram_data(C::FinCat, parse_ob, parse_hom, body::Expr; kw...)
  g, eqs = NamedGraph{Symbol,Union{Symbol,Nothing}}(), Pair[]
  F_ob, F_hom = [], []

  ast = parse_category_ast(body; kw...)
  for stmt in ast.statements
    @match stmt begin
      AST.ObOver(x, X) => begin
        parse!(g, AST.Ob(x))
        push!(F_ob, isnothing(X) ? nothing : parse_ob(X))
      end
      AST.HomOver(f, x, y, h) => begin
        e = parse!(g, AST.Hom(f, x, y))
        X, Y = F_ob[src(g,e)], F_ob[tgt(g,e)]
        push!(F_hom, parse_hom(h, X, Y))
        if isnothing(Y)
          # Infer codomain in base category from parsed homs.
          F_ob[tgt(g,e)] = codom(C, F_hom[end])
        end
      end
      AST.HomEq(lhs, rhs) =>
        push!(eqs, parse_path(g, lhs) => parse_path(g, rhs))
      _ => error("Cannot use statement $stmt in diagram definition")
    end
  end
  J = isempty(eqs) ? FinCat(g) : FinCat(g, eqs)
  (F_ob, F_hom, J)
end

# Data migrations
#################

""" A diagram without a codomain category.

An intermediate data representation used internally by the parser for the
[`@migration`](@ref) macro.
"""
struct DiagramData{T,ObMap,HomMap,Shape<:FinCat}
  ob_map::ObMap
  hom_map::HomMap
  shape::Shape

  function DiagramData{T}(ob_map::ObMap, hom_map::HomMap, shape::Shape) where
      {T,ObMap,HomMap,Shape<:FinCat}
    new{T,ObMap,HomMap,Shape}(ob_map, hom_map, shape)
  end
end

Diagrams.ob_map(d::DiagramData, x) = d.ob_map[x]
Diagrams.hom_map(d::DiagramData, f) = d.hom_map[f]
Diagrams.shape(d::DiagramData) = d.shape

""" A diagram morphism without a domain or codomain.

Like [`DiagramData`](@ref), an intermediate data representation used internally
by the parser for the [`@migration`](@ref) macro.
"""
struct DiagramHomData{T,ObMap,HomMap}
  ob_map::ObMap
  hom_map::HomMap

  function DiagramHomData{T}(ob_map::ObMap, hom_map::HomMap) where {T,ObMap,HomMap}
    new{T,ObMap,HomMap}(ob_map, hom_map)
  end
end

""" Contravariantly migrate data from one acset to another.

This macro is shorthand for defining a data migration using the
[`@migration`](@ref) macro and then calling the `migrate` function. If the
migration will be used multiple times, it is more efficient to perform these
steps separately, reusing the functor defined by `@migration`.

For more about the syntax and supported features, see [`@migration`](@ref).
"""
macro migrate(tgt_type, src_acset, body)
  quote
    let T = $(esc(tgt_type)), X = $(esc(src_acset))
      migrate(T, X, parse_migration(Presentation(T), Presentation(X),
                                    $(Meta.quot(body))))
    end
  end
end

""" Define a contravariant data migration.

This macro provides a DSL to specify a contravariant data migration from
``C``-sets to ``D``-sets for given schemas ``C`` and ``D``. A data migration is
defined by a functor from ``D`` to a category of queries on ``C``. Thus, every
object of ``D`` is assigned a query on ``C`` and every morphism of ``D`` is
assigned a morphism of queries, in a compatible way. Example usages are in the
unit tests. What follows is a technical reference.

Several categories of queries are supported by this macro:

1. Trivial queries, specified by a single object of ``C``. In this case, the
   macro simply defines a functor ``D → C`` and is equivalent to
   [`@finfunctor`](@ref) or [`@diagram`](@ref).
2. *Conjunctive queries*, specified by a diagram in ``C`` and evaluated as a
   finite limit.
3. *Gluing queries*, specified by a diagram in ``C`` and evaluated as a finite
   colimit. An important special case is *linear queries*, evaluated as a
   finite coproduct.
4. *Gluc queries* (gluings of conjunctive queries), specified by a diagram of
   diagrams in ``C`` and evaluated as a colimit of limits. An important special
   case is *duc queries* (disjoint unions of conjunctive queries), evaluated as
   a coproduct of limits.

The query category of the data migration is not specified explicitly but is
inferred from the queries used in the macro call. Implicit conversion is
performed: trivial queries can be coerced to conjunctive queries or gluing
queries, and conjunctive queries and gluing queries can both be coerced to gluc
queries. Due to the implicit conversion, the resulting functor out of ``D`` has
a single query type and thus a well-defined codomain.

Syntax for the right-hand sides of object assignments is:

- a symbol, giving object of ``C`` (query type: trivial)
- `@product ...` (query type: conjunctive)
- `@unit` (alias: `@terminal`, query type: conjunctive)
- `@join ...` (alias: `@limit`, query type: conjunctive)
- `@cases ...` (alias: `@coproduct`, query type: gluing)
- `@empty` (alias: `@initial`, query type: gluing)
- `@glue ...` (alias: `@colimit`, query type: gluing)

Thes query types supported by this macro generalize the kind of queries familiar
from relational databases. Less familiar is the concept of a morphism between
queries, derived from the concept of a morphism between diagrams in a category.
A query morphism is given by a functor between the diagrams' indexing categories
together with a natural transformation filling a triangle of the appropriate
shape. From a practical standpoint, the most important thing to remember is that
a morphism between conjunctive queries is contravariant with respect to the
diagram shapes, whereas a morphism between gluing queries is covariant. TODO:
Reference for more on this.
"""
macro migration(src_schema, body)
  :(parse_migration($(esc(src_schema)), $(Meta.quot(body))))
end
macro migration(tgt_schema, src_schema, body)
  :(parse_migration($(esc(tgt_schema)), $(esc(src_schema)), $(Meta.quot(body))))
end

""" Parse a contravariant data migration from a Julia expression.

The process kicked off by this internal function is somewhat complicated due to
the need to coerce queries and query morphisms to a common category. The
high-level steps of this process are:

1. Parse the queries and query morphisms into intermediate representations
   ([`DiagramData`](@ref) and [`DiagramHomData`](@ref)) whose final types are
   not yet determined.
2. Promote the query types to the tightest type encompassing all queries, an
   approach reminiscent of Julia's own type promotion system.
3. Convert all query and query morphisms to this common type, yielding `Diagram`
   and `DiagramHom` instances.
"""
function parse_migration(src_schema::Presentation, body::Expr;
                         preprocess::Bool=true)
  C = FinCat(src_schema)
  F_ob, F_hom, J = parse_query_diagram(C, body; free=false, preprocess=preprocess)
  make_migration_functor(F_ob, F_hom, J, C)
end
function parse_migration(tgt_schema::Presentation, src_schema::Presentation,
                         body::Expr; preprocess::Bool=true)
  D, C = FinCat(tgt_schema), FinCat(src_schema)
  if preprocess
    body = reparse_arrows(body)
  end
  ob_rhs, hom_rhs = parse_ob_hom_maps(D, body, missing_hom=true)
  F_ob = mapvals(expr -> parse_query(C, expr), ob_rhs)
  F_hom = mapvals(hom_rhs, keys=true) do f, expr
    parse_query_hom(C, ismissing(expr) ? Expr(:block) : expr,
                    F_ob[dom(D,f)], F_ob[codom(D,f)])
  end
  make_migration_functor(F_ob, F_hom, D, C)
end

# Query parsing
#--------------

""" Parse expression defining a query.
"""
function parse_query(C::FinCat, expr)
  expr = @match expr begin
    Expr(:macrocall, form, ::LineNumberNode, args...) =>
      Expr(:macrocall, form, args...)
    _ => expr
  end
  @match expr begin
    x::Symbol => ob_generator(C, x)
    Expr(:macrocall, &(Symbol("@limit")), body) ||
    Expr(:macrocall, &(Symbol("@join")), body) => begin
      DiagramData{op}(parse_query_diagram(C, body)...)
    end
    Expr(:macrocall, &(Symbol("@product")), body) => begin
      d = DiagramData{op}(parse_query_diagram(C, body)...)
      is_discrete(shape(d)) ? d : error("Product query is not discrete: $expr")
    end
    Expr(:macrocall, &(Symbol("@terminal"))) ||
    Expr(:macrocall, &(Symbol("@unit"))) => begin
      DiagramData{op}(parse_query_diagram(C, Expr(:block))...)
    end
    Expr(:macrocall, &(Symbol("@colimit")), body) ||
    Expr(:macrocall, &(Symbol("@glue")), body) => begin
      DiagramData{id}(parse_query_diagram(C, body)...)
    end
    Expr(:macrocall, &(Symbol("@coproduct")), body) ||
    Expr(:macrocall, &(Symbol("@cases")), body) => begin
      d = DiagramData{id}(parse_query_diagram(C, body)...)
      is_discrete(shape(d)) ? d : error("Cases query is not discrete: $expr")
    end
    Expr(:macrocall, &(Symbol("@initial"))) ||
    Expr(:macrocall, &(Symbol("@empty"))) => begin
      DiagramData{id}(parse_query_diagram(C, Expr(:block))...)
    end
    _ => error("Cannot parse query in definition of migration: $expr")
  end
end
function parse_query_diagram(C::FinCat, expr::Expr;
                             free::Bool=true, preprocess::Bool=false)
  parse_diagram_data(C, X -> parse_query(C,X),
                     (f,x,y) -> parse_query_hom(C,f,x,y), expr;
                     free=free, preprocess=preprocess)
end

""" Parse expression defining a morphism of queries.
"""
parse_query_hom(C::FinCat{Ob}, expr, ::Ob, ::Union{Ob,Nothing}) where Ob =
  parse_hom(C, expr)

# Conjunctive fragment.

function parse_query_hom(C::FinCat, expr, d::DiagramData{op}, d′::DiagramData{op})
  ob_rhs, hom_rhs = parse_ob_hom_maps(shape(d′), expr)
  f_ob = mapvals(ob_rhs, keys=true) do j′, rhs
    parse_conj_query_ob_rhs(C, rhs, d, ob_map(d′, j′))
  end
  f_hom = mapvals(rhs -> parse_hom(shape(d), rhs), hom_rhs)
  DiagramHomData{op}(f_ob, f_hom)
end
function parse_query_hom(C::FinCat{Ob}, expr, c::Ob, d′::DiagramData{op}) where Ob
  ob_rhs, f_hom = parse_ob_hom_maps(shape(d′), expr, missing_ob=true, missing_hom=true)
  f_ob = mapvals(ob_rhs, keys=true) do j′, rhs
    ismissing(rhs) ? missing : (missing, parse_query_hom(C, rhs, c, ob_map(d′, j′)))
  end
  @assert all(ismissing, f_hom)
  DiagramHomData{op}(f_ob, f_hom)
end
function parse_query_hom(C::FinCat{Ob}, expr, d::DiagramData{op}, c′::Ob) where Ob
  DiagramHomData{op}([parse_conj_query_ob_rhs(C, expr, d, c′)], [])
end

# Gluing fragment.

function parse_query_hom(C::FinCat, expr, d::DiagramData{id}, d′::DiagramData{id})
  ob_rhs, hom_rhs = parse_ob_hom_maps(shape(d), expr)
  f_ob = mapvals(ob_rhs, keys=true) do j, rhs
    parse_glue_query_ob_rhs(C, rhs, ob_map(d, j), d′)
  end
  f_hom = mapvals(expr -> parse_hom(shape(d′), expr), hom_rhs)
  DiagramHomData{id}(f_ob, f_hom)
end
function parse_query_hom(C::FinCat{Ob}, expr, c::Union{Ob,DiagramData{op}},
                         d′::DiagramData{id}) where Ob
  DiagramHomData{id}([parse_glue_query_ob_rhs(C, expr, c, d′)], [])
end
function parse_query_hom(C::FinCat{Ob}, expr, d::DiagramData{id},
                         c′::Union{Ob,DiagramData{op}}) where Ob
  ob_rhs, f_hom = parse_ob_hom_maps(shape(d), expr, missing_ob=true, missing_hom=true)
  f_ob = mapvals(ob_rhs, keys=true) do j, rhs
    ismissing(rhs) ? missing : (missing, parse_query_hom(C, rhs, ob_map(d, j), c′))
  end
  @assert all(ismissing, f_hom)
  DiagramHomData{id}(f_ob, f_hom)
end

""" Parse RHS of object assignment in morphism out of conjunctive query.
"""
function parse_conj_query_ob_rhs(C::FinCat, expr, d::DiagramData{op}, c′)
  j_name, f_expr = @match expr begin
    x::Symbol => (x, nothing)
    Expr(:tuple, x::Symbol, f) => (x, f)
    Expr(:call, op, _...) && if op ∈ compose_ops end =>
      leftmost_arg(expr, (:(⋅), :(⨟)), all_ops=compose_ops)
    Expr(:call, name::Symbol, _) => reverse(destructure_unary_call(expr))
    _ => error("Cannot parse object assignment in migration: $expr")
  end
  j = ob_generator(shape(d), j_name)
  isnothing(f_expr) ? j :
    (j, parse_query_hom(C, f_expr, ob_map(d, j), c′))
end

""" Parse RHS of object assignment in morphism into gluing query.
"""
function parse_glue_query_ob_rhs(C::FinCat, expr, c, d′::DiagramData{id})
  j′_name, f_expr = @match expr begin
    x::Symbol => (x, nothing)
    Expr(:tuple, x::Symbol, f) => (x, f)
    Expr(:call, op, _...) && if op ∈ compose_ops end =>
      leftmost_arg(expr, (:(∘),), all_ops=compose_ops)
    _ => error("Cannot parse object assignment in migration: $expr")
  end
  j′ = ob_generator(shape(d′), j′_name)
  isnothing(f_expr) ? j′ :
    (j′, parse_query_hom(C, f_expr, c, ob_map(d′, j′)))
end

const compose_ops = (:(⋅), :(⨟), :(∘))

# Query construction
#-------------------

function make_migration_functor(F_ob, F_hom, D::FinCat, C::FinCat)
  diagram(make_query(C, DiagramData{id}(F_ob, F_hom, D)))
end

function make_query(C::FinCat{Ob}, d::DiagramData{T}) where {T, Ob}
  F_ob, F_hom, J = d.ob_map, d.hom_map, shape(d)
  F_ob = mapvals(x -> make_query(C, x), F_ob)
  query_type = mapreduce(typeof, promote_query_type, values(F_ob), init=Ob)
  @assert query_type != Any
  F_ob = mapvals(x -> convert_query(C, query_type, x), F_ob)
  F_hom = mapvals(F_hom, keys=true) do h, f
    make_query_hom(f, F_ob[dom(J,h)], F_ob[codom(J,h)])
  end
  Diagram{T}(if query_type <: Ob
    FinFunctor(F_ob, F_hom, shape(d), C)
  else
    # XXX: Why is the element type of `F_ob` sometimes too loose?
    D = TypeCat(typeintersect(query_type, eltype(values(F_ob))),
                eltype(values(F_hom)))
    FinDomFunctor(F_ob, F_hom, shape(d), D)

  end)
end

make_query(C::FinCat{Ob}, x::Ob) where Ob = x

function make_query_hom(f::DiagramHomData{op}, d::Diagram{op}, d′::Diagram{op})
  f_ob = mapvals(f.ob_map, keys=true) do j′, x
    x = @match x begin
      ::Missing => only_ob(shape(d))
      (::Missing, g) => (only_ob(shape(d)), g)
      _ => x
    end
    @match x begin
      (j, g) => Pair(j, make_query_hom(g, ob_map(d, j), ob_map(d′, j′)))
      j => j
    end
  end
  f_hom = mapvals(h -> ismissing(h) ? only_hom(shape(d)) : h, f.hom_map)
  DiagramHom{op}(f_ob, f_hom, d, d′)
end

function make_query_hom(f::DiagramHomData{id}, d::Diagram{id}, d′::Diagram{id})
  f_ob = mapvals(f.ob_map, keys=true) do j, x
    x = @match x begin
      ::Missing => only_ob(shape(d′))
      (::Missing, g) => (only_ob(shape(d′)), g)
      _ => x
    end
    @match x begin
      (j′, g) => Pair(j′, make_query_hom(g, ob_map(d, j), ob_map(d′, j′)))
      j′ => j′
    end
  end
  f_hom = mapvals(h -> ismissing(h) ? only_hom(shape(d′)) : h, f.hom_map)
  DiagramHom{id}(f_ob, f_hom, d, d′)
end

function make_query_hom(f::Hom, d::Diagram{T,C}, d′::Diagram{T,C}) where
    {T, Ob, Hom, C<:FinCat{Ob,Hom}}
  cat = codom(diagram(d))
  munit(DiagramHom{T}, cat, f, dom_shape=shape(d), codom_shape=shape(d′))
end
make_query_hom(f, x, y) = f

only_ob(C::FinCat) = only(ob_generators(C))
only_hom(C::FinCat) = (@assert is_discrete(C); id(C, only_ob(C)))

# Query promotion
#----------------

# Promotion of query types is modeled loosely on Julia's type promotion system:
# https://docs.julialang.org/en/v1/manual/conversion-and-promotion/

promote_query_rule(::Type, ::Type) = Union{}
promote_query_rule(::Type{<:ConjQuery{C}}, ::Type{<:Ob}) where {Ob,C<:FinCat{Ob}} =
  ConjQuery{C}
promote_query_rule(::Type{<:GlueQuery{C}}, ::Type{<:Ob}) where {Ob,C<:FinCat{Ob}} =
  GlueQuery{C}
promote_query_rule(::Type{<:GlucQuery{C}}, ::Type{<:Ob}) where {Ob,C<:FinCat{Ob}} =
  GlucQuery{C}
promote_query_rule(::Type{<:GlucQuery{C}}, ::Type{<:ConjQuery{C}}) where C =
  GlucQuery{C}
promote_query_rule(::Type{<:GlucQuery{C}}, ::Type{<:GlueQuery{C}}) where C =
  GlucQuery{C}

promote_query_type(T, S) = promote_query_result(
  T, S, Union{promote_query_rule(T,S), promote_query_rule(S,T)})
promote_query_result(T, S, ::Type{Union{}}) = typejoin(T, S)
promote_query_result(T, S, U) = U

convert_query(::FinCat, ::Type{T}, x::S) where {T, S<:T} = x

function convert_query(cat::C, ::Type{<:Diagram{T,C}}, x::Ob) where
  {T, Ob, C<:FinCat{Ob}}
  g = NamedGraph{Symbol,Symbol}(1, vname=nameof(x))
  munit(Diagram{T}, cat, x, shape=FinCat(g))
end
function convert_query(::C, ::Type{<:GlucQuery{C}}, d::ConjQuery{C}) where C
  munit(Diagram{id}, TypeCat(ConjQuery{C}, Any), d)
end
function convert_query(cat::C, ::Type{<:GlucQuery{C}}, d::GlueQuery{C}) where C
  J = shape(d)
  new_ob = make_map(ob_generators(J)) do j
    convert_query(cat, ConjQuery{C}, ob_map(d, j))
  end
  new_hom = make_map(hom_generators(J)) do h
    munit(Diagram{op}, cat, hom_map(d, h),
          dom_shape=new_ob[dom(J,h)], codom_shape=new_ob[codom(J,h)])
  end
  Diagram{id}(FinDomFunctor(new_ob, new_hom, J))
end
function convert_query(cat::C, ::Type{<:GlucQuery{C}}, x::Ob) where
    {Ob, C<:FinCat{Ob}}
  convert_query(cat, GlucQuery{C}, convert_query(cat, ConjQuery{C}, x))
end

# Utilities
###########

""" Left-most argument plus remainder of left-associated binary operations.
"""
function leftmost_arg(expr, ops; all_ops=nothing)
  isnothing(all_ops) && (all_ops = ops)
  function leftmost(expr)
    @match expr begin
      Expr(:call, op2, Expr(:call, op1, x, y), z) &&
          if op1 ∈ all_ops && op2 ∈ all_ops end => begin
        x, rest = leftmost(Expr(:call, op1, x, y))
        (x, Expr(:call, op2, rest, z))
      end
      Expr(:call, op, x, y) && if op ∈ ops end => (x, y)
      _ => (nothing, expr)
    end
  end
  leftmost(expr)
end

end
