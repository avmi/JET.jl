using JET, InteractiveUtils

const CC = JET.CC

import .CC:
    widenconst, ⊑

import JET:
    JETInterpreter,
    AbstractGlobal,
    analyze_call,
    get_result,
    virtual_process!,
    gen_virtual_module,
    ToplevelErrorReport,
    InferenceErrorReport,
    ExceptionReport,
    print_reports

for sym in Symbol.(last.(Base.Fix2(split, '.').(string.(vcat(subtypes(JET, ToplevelErrorReport),
                                                             subtypes(JET, InferenceErrorReport),
                                                             subtypes(JET, ExceptionReport),
                                                             )))))
    Core.eval(@__MODULE__, :(import JET: $(sym)))
end

import Base:
    Fix1,
    Fix2

import Base.Meta:
    isexpr

# define virtual module and setup fixtures
macro def(ex)
    @assert isexpr(ex, :block)
    return quote let
        vmod = $(gen_virtual_module)()
        for x in $(ex.args)
            Core.eval(vmod, x)
        end
        vmod # return virtual module
    end end
end

# enters analysis from file name
analyze_file(filename, args...; kwargs...) =
    return analyze_text(read(filename, String), args...; filename, kwargs...)

# enters analysis from string
function analyze_text(s,
                      virtualmod = gen_virtual_module(@__MODULE__);
                      filename = "top-level",
                      actualmodsym = Symbol(parentmodule(virtualmod)),
                      interp = JETInterpreter(),
                      )
    return virtual_process!(s,
                            filename,
                            virtualmod,
                            actualmodsym,
                            interp)
end

# enters analysis from toplevel expression
macro analyze_toplevel(virtualmod, ex)
    return analyze_toplevel(virtualmod, ex, __source__)
end

macro analyze_toplevel(ex)
    virtualmod = gen_virtual_module(__module__)
    return analyze_toplevel(virtualmod, ex, __source__)
end

function analyze_toplevel(virtualmod, ex, lnn)
    toplevelex = (isexpr(ex, :block) ?
                  Expr(:toplevel, lnn, ex.args...) : # flatten here
                  Expr(:toplevel, lnn, ex)
                  ) |> QuoteNode
    return quote let
        interp = $(JETInterpreter)()
        ret = $(JET.gen_virtual_process_result)()
        virtualmod = $(esc(virtualmod))
        actualmodsym = Symbol(parentmodule(virtualmod))
        $(virtual_process!)($(toplevelex), $(string(lnn.file)), virtualmod, actualmodsym, interp, ret)
    end end
end

is_concrete(mod, sym) = isdefined(mod, sym) && !isa(getfield(mod, sym), AbstractGlobal)
is_abstract(mod, sym) = isdefined(mod, sym) && isa(getfield(mod, sym), AbstractGlobal)
isa_abstract(x, @nospecialize(typ)) = isa(x, AbstractGlobal) && x.t ⊑ typ

# fresh execution/benchmark tools
include(normpath(@__DIR__, "..", "benchmark", "JETBenchmarkUtils.jl"))
using .JETBenchmarkUtils