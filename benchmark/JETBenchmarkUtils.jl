module JETBenchmarkUtils

export
    FreshPass,
    @freshbenchmarkable,
    @freshexec,
    @benchmark_freshexec

using Base.Meta: isexpr
using BenchmarkTools: @benchmarkable
using JET.JETInterface

"""
    FreshPass(inner::ReportPass)

A special `ReportPass` with which a single JET analysis runs without being influenced by
caches generated by previous analyses.

```julia
julia> @benchmark @report_call report_pass=JET.BasicPass() sum("julia")
BenchmarkTools.Trial: 10000 samples with 1 evaluation.
 Range (min … max):  110.591 μs …  13.035 ms  ┊ GC (min … max):  0.00% … 98.36%
 Time  (median):     124.728 μs               ┊ GC (median):     0.00%
 Time  (mean ± σ):   157.072 μs ± 497.050 μs  ┊ GC (mean ± σ):  12.42% ±  3.89%

  ▅█▇▇▆▆▅▄▃▄▃▃▂▂▂▁▁                                             ▂
  ███████████████████████▇▇▆▇▇▇▇▆▇▅▇▆▇▇▅▇▅▅▆▆▅▄▄▇▆▆▄▅▆▅▅▅▅▅▄▄▄▅ █
  111 μs        Histogram: log(frequency) by time        353 μs <

 Memory estimate: 74.89 KiB, allocs estimate: 1103.

julia> @benchmark @report_call report_pass=FreshPass(JET.BasicPass()) sum("julia")
BenchmarkTools.Trial: 241 samples with 1 evaluation.
 Range (min … max):  16.070 ms … 43.320 ms  ┊ GC (min … max):  0.00% … 56.07%
 Time  (median):     17.484 ms              ┊ GC (median):     0.00%
 Time  (mean ± σ):   20.765 ms ±  6.673 ms  ┊ GC (mean ± σ):  14.31% ± 18.26%

  ▄██▇▅▂▂                                  ▂
  ███████▅▆▅▅▅█▇▁▁▅▇▇▁▆▁▁▁▁▁▁▁▁▁▁▁▁▁▅▁▅▁▇█████▆▅▆▁▁▅▅▁▅▆▁▁▁▅▅ ▆
  16.1 ms      Histogram: log(frequency) by time      39.9 ms <

 Memory estimate: 8.45 MiB, allocs estimate: 127142.
```
"""
struct FreshPass{RP<:ReportPass} <: ReportPass
    inner::RP
    id::UInt
    # HACK generate different `cache_key` for each construction
    let id = zero(UInt)
        global function FreshPass(inner::RP) where RP<:ReportPass
            id += 1
            return new{RP}(inner, id)
        end
    end
end
(rp::FreshPass)(@nospecialize(args...)) = rp.inner(args...)

"""
    @freshbenchmarkable ex [benchmark_params...]

Defines `BenchmarkTools.@benchmarkable` of the fresh execution of `ex`.
Each "evaluation" of `ex` is done in new Julia process in order to benchmark the performance
of the "first-time analysis".

!!! warning
    Note that the current design of `@freshbenchmarkable` allows us to collect only execution
    time, and the other execution statistics like memory estimate are not available.
"""
macro freshbenchmarkable(ex, benchmark_params...)
    benchmark_params = collect(benchmark_params)
    issetup(x) = isexpr(x, :(=)) && first(x.args) === :setup
    i = findfirst(issetup, benchmark_params)
    setup_ex = i === nothing ? nothing : last(popat!(benchmark_params, i).args)
    isevals(x) = isexpr(x, :(=)) && first(x.args) === :evals
    any(isevals, benchmark_params) && throw(ArgumentError("@freshbenchmarkable doesn't accept `evals` option"))

    filename = string(__source__.file)
    runner_code = :(while true
        s = readuntil(stdin, "JET_BENCHMARK_INPUT_EOL")
        try
            include_string(Main, s, $filename)
        catch err
            showerror(stderr, err, stacktrace(catch_backtrace()))
        finally
            println(stdout, "JET_BENCHMARK_OUTPUT_EOL")
        end
    end) |> string

    # we need to flatten block expression into a toplevel expression to correctly handle
    # e.g. macro expansions
    setup_exs = isexpr(setup_ex, :block) ? setup_ex.args : [setup_ex]
    setup_code = join(string.(setup_exs), '\n')
    exs = isexpr(ex, :block) ? ex.args : [ex]
    benchmark_code = join(string.(exs), '\n')

    return quote
        @benchmarkable begin
            write(stdin, $benchmark_code, "JET_BENCHMARK_INPUT_EOL")
            readuntil(stdout, "JET_BENCHMARK_OUTPUT_EOL")

            err = String(take!(stderr))
            if !isempty(err)
                kill(proc)
                println(err)
                throw(ErrorException("error happened while @freshbenchmarkable"))
            end
        end setup = begin
            stdin  = Base.BufferStream()
            stdout = Base.BufferStream()
            stderr = IOBuffer()

            cmd = String[normpath(Sys.BINDIR, "julia"),
                         "--project=@.",
                         "-e",
                         $runner_code]
            pipe = pipeline(Cmd(cmd); stdin, stdout, stderr)
            proc = run(pipe; wait = false)

            write(stdin, $setup_code, "JET_BENCHMARK_INPUT_EOL")
            readuntil(stdout, "JET_BENCHMARK_OUTPUT_EOL")

            err = String(take!(stderr))
            if !isempty(err)
                kill(proc)
                println(err)
                throw(ErrorException("error happened while @freshbenchmarkable setup"))
            end
        end teardown = begin
            kill(proc)
        end $(benchmark_params...)
    end
end

"""
    ret = @freshexec [setup_ex] ex

Runs `ex` in an external process and gets back the final result (, which is supposed to be
such a simple Julia object that we can restore it from its string representation).

Running in external process can be useful for testing JET analysis, because:
- the first time analysis is not affected by native code cache and JET's global report cache
- we can do something that might break a Julia process without wondering it breaks the
  original test process later on

The optional positional argument `setup_ex` runs before each execution of `ex` and defaults
to `JET_LOAD_EX`, which just loads JET into the process.
"""
macro freshexec(args...)
    args = map(a->Expr(:quote,a), args)
    return Expr(:escape, Expr(:call, GlobalRef(@__MODULE__, :freshexec), __module__, args...))
end
freshexec(mod, ex) = freshexec(mod, JET_LOAD_EX, ex)
freshexec(args...) = _freshexec(args..., collect_last_result)

function collect_last_result(exs)
    lines = string.(exs)
    lines[end] = "ret = $(lines[end])"
    return join(lines, '\n')
end

"""
    stats = @benchmark_freshexec [ntimes = 5] [setup_ex] ex

Runs `ex` in an external process multiple times (which can be configured by the optional
keyword argument `ntimes`), and collects execution statistics from [`@timed`](@ref).
The final result is the statistics from a trial with minimum execution time.
The statistics are generated by taking the `mean` of all the trials.

Each "evaluation" of `ex` is done in new Julia process in order to benchmark the performance
of the "first-time analysis", where the native code cache and JET's global report cache
have no effect for execution (of course, this is very time-consuming though ...).

The optional positional argument `setup_ex` runs before each execution of `ex` and its
execution statistis are not included in the benchmark result; it defaults to
`JET_WARMUP_EX`, which loads JET and runs a warm up analysis `@report_call identity(nothing)`.

!!! note
    `@benchmark_freshexec` is not integrated with [BenchmarkTools.jl](https://github.com/JuliaCI/BenchmarkTools.jl)'s CI infrastructure.
"""
macro benchmark_freshexec(args...)
    isn(x) = isexpr(x, :(=)) && first(x.args) === :ntimes
    i = findfirst(isn, args)
    ntimes = i === nothing ? 5 : Expr(:quote, last(args[i].args))
    args = map(a->Expr(:quote,a), filter(!isn, args))
    return Expr(:escape, Expr(:call, GlobalRef(@__MODULE__, :benchmark_freshexec), ntimes, __module__, args...))
end
benchmark_freshexec(ntimes, mod, ex) = benchmark_freshexec(ntimes, mod, JET_WARMUP_EX, ex)
function benchmark_freshexec(ntimes, args...)
    stats = [_freshexec(args..., collect_statistics) for _ in 1:ntimes]
    return stats[argmin(getproperty.(stats, :time))]
end

function collect_statistics(exs)
    return """
    ret = @timed begin
        $(join(exs, '\n'))
        nothing # ensure `stats` can be parsed
    end
    """
end

function _freshexec(mod, setup_ex, ex, exs2script)
    # we need to flatten block expression into a toplevel expression to correctly handle
    # e.g. macro expansions
    setup_exs = isexpr(setup_ex, :block) ? setup_ex.args : [setup_ex]
    setup_script = join(string.(setup_exs), '\n')
    exs = isexpr(ex, :block) ? ex.args : [ex]
    script = exs2script(exs)

    prog = """
    old = stdout
    rw, wr = redirect_stdout()
    $(setup_script)
    $(script)
    redirect_stdout(old)
    close(rw); close(wr)
    println(stdout, repr(ret))
    """

    cmd = Cmd([JULIA_BIN, "-e", prog])
    io = IOBuffer()
    run(pipeline(cmd; stdout = io))

    return Core.eval(mod, Meta.parse(String(take!(io))))
end

const JET_LOAD_EX = :(using JET)
const JET_WARMUP_EX = quote
    using JET
    @report_call identity(nothing) # warm-up for JET analysis
end
const JULIA_BIN = normpath(Sys.BINDIR, "julia")

end
