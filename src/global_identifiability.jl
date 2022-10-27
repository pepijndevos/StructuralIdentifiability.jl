# ------------------------------------------------------------------------------
"""
    check_field_membership(generators, rat_funcs, p, [method=:GroebnerBasis])

Checks whether given rational function belogn to a given field of rational functions

Inputs:
- `generators` - a list of lists of polynomials. Each of the lists, say, `[f1, ..., fn]`,
  defines generators `f2/f1, ..., fn/f1`. Let ``F`` be the field generated by all of them.
- `rat_funcs` - list rational functions
- `p` - a real number between 0 and 1, the probability of correctness

Output: 
- a list `L[i]` of bools of length `length(rat_funcs)` such that `L[i]` is true iff
   the i-th function belongs to ``F``. The whole result is correct with probability at least p
"""
function check_field_membership(
        generators::Array{<: Array{<: MPolyElem,1},1},
        rat_funcs::Array{<: Any,1},
        p::Float64)
    @debug "Finding pivot polynomials"
    pivots = map(plist -> plist[findmin(map(total_degree, plist))[2]], generators)
    @debug "\tDegrees are $(map(total_degree, pivots))"

    @debug "Sampling the point"
    flush(stdout)
    ring = parent(first(first(generators)))

    total_lcm = foldl(lcm, pivots)
    total_lcm = foldl(lcm, map(f -> unpack_fraction(f)[2], rat_funcs); init=total_lcm)
    degree = total_degree(total_lcm) + 1
    for (i, plist) in enumerate(generators)
        extra_degree = total_degree(total_lcm) - total_degree(pivots[i])
        degree = max(degree, extra_degree + max(map(total_degree, plist)...))
    end
    for f in rat_funcs
        num, den = unpack_fraction(f)
        degree = max(degree, total_degree(total_lcm) - total_degree(den) + total_degree(num))
    end
    @debug "\tBound for the degrees is $degree"
    total_vars = foldl(
        union, 
        map(plist -> foldl(union, map(poly -> Set(vars(poly)), plist)), generators)
    )
    @debug "\tThe total number of variables in $(length(total_vars))"

    sampling_bound = BigInt(3 * BigInt(degree)^(length(total_vars) + 3) * length(rat_funcs) * ceil(1 / (1 - p)))
    # sampling_bound = 5
    @debug "\tSampling from $(-sampling_bound) to $(sampling_bound)"
    point = map(v -> rand(-sampling_bound:sampling_bound), gens(ring))
    @debug "\tPoint is $point"

    @debug "Constructing the equations"
    eqs = Array{Any, 1}()
    ring_ext, vars_ext = Nemo.PolynomialRing(
        Nemo.QQ, 
        vcat(map(var_to_str, gens(ring)), ["sat_aux$i" for i in 1:length(generators)]);
        ordering=:degrevlex
    )

    for (i, component) in enumerate(generators)
        pivot = pivots[i]
        @debug "\tPivot polynomial is $(pivot)"
        eqs_comp = []
        for poly in component
            push!(eqs_comp, poly * evaluate(ring(pivot), point) - evaluate(ring(poly), point) * pivot)
        end
        append!(eqs, map(p -> parent_ring_change(p, ring_ext), eqs_comp))
        push!(
            eqs,
            parent_ring_change(pivot, ring_ext) * vars_ext[end - i + 1] - 1
        )
    end
   
    eqs = [e for e in eqs if !iszero(e)]
    @debug "VARS $(vars_ext)"
    @debug "GB $eqs"

    @debug "Computing Groebner basis ($(length(eqs)) equations)"
    flush(stdout)
    # to uncomment certify
    # gb = groebner(eqs; certify=true, linalg=:prob)
    gb_loglevel = Logging.Warn
    if Logging.min_enabled_level(Logging.current_logger()) == Logging.Debug
        gb_loglevel = Logging.Debug
    end
    gb = groebner(eqs; linalg=:prob, loglevel=gb_loglevel)
    if isequal(one(ring_ext), gb[1])
        @error "The Groebner basis computation resulted in the unit ideal. This is an incorrect result, 
        please, run the code again. Sorry for the inconvenience"
        throw("GB problem")
    end

    @debug "Producing the result"
    flush(stdout)
    result = []
    for f in rat_funcs
        num, den = unpack_fraction(f)
        poly = num * evaluate(den, point) - den * evaluate(num, point)
        poly_ext = parent_ring_change(poly, ring_ext)
	# poly_ext = evaluate(poly_ext, shift)
        push!(result, iszero(normalform(gb, poly_ext)))
    end
    return result
end

# ------------------------------------------------------------------------------



function check_identifiability(
        io_equations::Array{P,1}, 
        parameters::Array{P,1},
        known::Array{P, 1},
        funcs_to_check::Array{<: Any,1},
        p::Float64=0.99
    ) where P <: MPolyElem{fmpq}
    @debug "Extracting coefficients"
    flush(stdout)
    nonparameters = filter(v -> !(var_to_str(v) in map(var_to_str, parameters)), gens(parent(io_equations[1])))
    coeff_lists = Array{Array{P,1},1}()
    for eq in io_equations
        push!(coeff_lists, collect(values(extract_coefficients(eq, nonparameters))))
    end
    bring = parent(first(first(coeff_lists)))
    for p in known
        push!(coeff_lists, [one(bring), parent_ring_change(p, bring)])
    end
    for p in coeff_lists
        @debug sort(map(total_degree, p))
    end
    ring = parent(first(first(coeff_lists)))
    funcs_to_check = map(f -> parent_ring_change(f, ring), funcs_to_check)

    return check_field_membership(coeff_lists, funcs_to_check, p)
end

function check_identifiability(
        io_equation::P,
        parameters::Array{P,1},
        known::Array{P, 1},
        funcs_to_check::Array{<: Any,1}, 
        p::Float64=0.99 
    ) where P <: MPolyElem{fmpq}
    return check_identifiability([io_equation], parameters, known, funcs_to_check, p)
end

function check_identifiability(io_equations::Array{P,1}, parameters::Array{P,1}, known::Array{P, 1}, p::Float64=0.99) where P <: MPolyElem{fmpq}
    check_identifiability(io_equations, parameters, known, parameters, p)
end

function check_identifiability(io_equation::P, parameters::Array{P,1}, known::Array{P, 1}, p::Float64=0.99) where P <: MPolyElem{fmpq}
    return check_identifiability([io_equation], parameters, known, p)
end

#------------------------------------------------------------------------------
"""
    assess_global_identifiability(ode::ODE{P}, p::Float64=0.99; var_change=:default) where P <: MPolyElem{fmpq}

Input:
- `ode` - the ODE model
- `p` - probability of correctness
- `var_change` - a policy for variable change (`:default`, `:yes`, `:no`), affects only the runtime

Output: 
- a dictionary mapping each parameter to a boolean.

Checks global identifiability for a parameters of the model provided in `ode`. Call this function to check global identifiability of all parameters automatically.
"""
function assess_global_identifiability(
        ode::ODE{P},
        known::Array{P, 1}=Array{P, 1}(),
        p::Float64=0.99; 
        var_change=:default
    ) where P <: MPolyElem{fmpq}
    result_list = assess_global_identifiability(ode, ode.parameters, known, p; var_change=var_change)

    return Dict(param => val for (param, val) in zip(ode.parameters, result_list))
end

#------------------------------------------------------------------------------

"""
    assess_global_identifiability(ode, [funcs_to_check, p=0.99, var_change=:default])

Input:
- `ode` - the ODE model
- `funcs_to_check` - rational functions in parameters
- `known` - function in parameters that may assumed to be known
- `p` - probability of correctness
- `var_change` - a policy for variable change (`:default`, `:yes`, `:no`),
                affects only the runtime

Output: 
- array of length `length(funcs_to_check)` with true/false values for global identifiability
        or dictionary `param => Bool` if `funcs_to_check` are not given

Checks global identifiability of functions of parameters specified in `funcs_to_check`.
"""
function assess_global_identifiability(
        ode::ODE{P},
        funcs_to_check::Array{<: Any,1},
        known::Array{P, 1}=Array{P, 1}(),
        p::Float64=0.99;
        var_change=:default,
    ) where P <: MPolyElem{fmpq}
    @info "Computing IO-equations"
    ioeq_time = @elapsed io_equations = find_ioequations(ode; var_change_policy=var_change)
    @debug "Sizes: $(map(length, values(io_equations)))"
    @info "Computed in $ioeq_time seconds" :ioeq_time ioeq_time
    _runtime_logger[:ioeq_time] = ioeq_time

    @info "Computing Wronskians"
    wrnsk_time = @elapsed wrnsk = wronskian(io_equations, ode)
    @info "Computed in $wrnsk_time seconds" :wrnsk_time wrnsk_time
    _runtime_logger[:wrnsk_time] = wrnsk_time

    dims = map(ncols, wrnsk)
    @info "Dimensions of the wronskians $dims"

    rank_times = @elapsed wranks = map(rank, wrnsk)
    @debug "Dimensions of the wronskians $dims"
    @debug "Ranks of the wronskians $wranks"
    @info "Ranks of the Wronskians computed in $rank_times seconds" :rank_time rank_times
    _runtime_logger[:rank_time] = rank_times

    if any([dim != rk + 1 for (dim, rk) in zip(dims, wranks)])
        @warn "One of the Wronskians has corank greater than one, so the results of the algorithm will be valid only for multiexperiment identifiability. If you still  would like to assess single-experiment identifiability, we recommend using SIAN (https://github.com/alexeyovchinnikov/SIAN-Julia)"
    end

    @info "Assessing global identifiability using the coefficients of the io-equations"
    check_time = @elapsed result = check_identifiability(collect(values(io_equations)), ode.parameters, known, funcs_to_check, p)
    @info "Computed in $check_time seconds" :check_time check_time
    _runtime_logger[:check_time] = check_time

    return result
end

#------------------------------------------------------------------------------

"""
    extract_identifiable_functions(io_equations, parameters)

For the io_equation and the list of all parameter variables, returns a set of generators of a field of all functions of parameters

Note: an experimental functionality at the moment, may fail be inefficient
"""
function extract_identifiable_functions(
    io_equations::Array{P,1}, 
    parameters::Array{P,1}, 
    known_functions::Array{P,1}
) where P <: MPolyElem{fmpq}
    @debug "Extracting coefficients"
    flush(stdout)
    nonparameters = filter(v -> !(var_to_str(v) in map(var_to_str, parameters)), gens(parent(io_equations[1])))
    coeff_lists = Array{Array{P,1},1}()
    for eq in io_equations
        push!(coeff_lists, collect(values(extract_coefficients(eq, nonparameters))))
    end
    for f in known_functions
        push!(coeff_lists, [one(parent(f)), f])
    end
    for p in coeff_lists
        @debug sort(map(total_degree, p))
    end

    @debug "Resulting Coefficient List: $coeff_lists"
    
    return simplify_field_generators(coeff_lists)
end

#------------------------------------------------------------------------------

"""
    extract_identifiable_functions_raw(io_equations, parameters)

For the io_equation and the list of all parameter variables, returns a set of *raw* *generators of a field of all functions of parameters
"""
function extract_identifiable_functions_raw(
    io_equations::Array{P,1}, 
    parameters::Array{P,1}, 
) where P <: MPolyElem{fmpq}
    @debug "Extracting coefficients"
    flush(stdout)
    nonparameters = filter(v -> !(var_to_str(v) in map(var_to_str, parameters)), gens(parent(io_equations[1])))
    result = []
    for eq in io_equations
        coeffs = sort(collect(values(extract_coefficients(eq, nonparameters))), by = total_degree)
        append!(result, [c // first(coeffs) for c in coeffs[2:end]])
    end

    return result
end


#------------------------------------------------------------------------------

"""
    find_identifiable_functions(ode::ODE{<: MPolyElem{fmpq}}, p::Float64=0.99)

Input:
- `ode` - `ODE`-system
- `p` - probability of correctness

Output:
- returns a set of generators of the field of all functions of parameters

Find identifiable functions of parameters for a given `ode`. 
"""
function find_identifiable_functions(ode::ODE{<: MPolyElem{fmpq}}, p::Float64=0.99)
    @debug "Computing IO-equations"
    io_equations = find_ioequations(ode)
    global_result = check_identifiability(collect(values(io_equations)), ode.parameters, p)
    known_params = Array{fmpq_mpoly,1}()
    for (glob, p) in zip(global_result, ode.parameters)
        if glob
            push!(known_params, p)
        end
    end
    return extract_identifiable_functions(collect(values(io_equations)), ode.parameters, known_params)
end
